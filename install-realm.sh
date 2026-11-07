#!/usr/bin/env bash
# realm 管理工具：仅管理本工具创建的配置及服务。
set -uo pipefail

DIR=/opt/realm-manager
CONFIG=$DIR/config.toml
BIN=$DIR/realm
UNIT=/etc/systemd/system/realm-manager.service
TIMER=/etc/systemd/system/realm-manager-restart.timer
TIMER_SERVICE=/etc/systemd/system/realm-manager-restart.service

die() { echo "错误：$*" >&2; return 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 或 sudo 运行。'; }
installed() { [[ -x $BIN && -f $CONFIG && -f $UNIT ]] || die '请先安装 realm。'; }
port_ok() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

check_environment() {
  if [[ ! -r /etc/os-release ]]; then die '无法识别系统，本脚本仅支持 Debian。'; return; fi
  local ID VERSION_ID
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ $ID == debian ]] || { die '本脚本仅支持 Debian。'; return; }
  need_root || return
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null || { die '需要已启动的 systemd。'; return; }
}

check_dependencies() {
  local missing=() cmd answer
  for cmd in curl tar python3; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done
  if ((${#missing[@]})); then
    printf '缺少依赖：%s\n' "${missing[*]}"
    read -r -p '是否使用 apt 安装缺少的依赖？[y/N] ' answer || return 1
    [[ $answer == [yY] ]] || { die '请先安装所需依赖。'; return; }
    apt-get update && apt-get install -y "${missing[@]}" || { die '依赖安装失败。'; return; }
  fi
  python3 -c 'import tomllib' 2>/dev/null || { die '需要 Python 3.11 或更高版本（Debian 12/13 自带）。'; return; }
}

install_realm() {
  need_root || return
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { die '需要使用 systemd 的 Linux 系统。'; return; }
  check_dependencies || return
  case $(uname -m) in
    x86_64) arch=x86_64;; aarch64|arm64) arch=aarch64;; *) die '仅支持 x86_64 和 aarch64。'; return;;
  esac
  if [[ -e $UNIT || -e $BIN ]]; then die '已存在本工具的安装；为保护现有数据，请先卸载。'; return; fi
  local tmp url version asset arch
  tmp=$(mktemp -d) || return
  asset="realm-${arch}-unknown-linux-musl.tar.gz"
  if ! curl -fLsS --retry 3 -H 'Accept: application/vnd.github+json' \
    -o "$tmp/release.json" 'https://api.github.com/repos/zhboner/realm/releases/latest'; then
    rm -rf "$tmp"; die '无法获取 Realm 最新稳定版信息，请检查网络或 GitHub API 限流。'; return
  fi
  if ! python3 - "$tmp/release.json" "$asset" "$tmp/metadata" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        release = json.load(f)
    version = release['tag_name']
    asset = next(item for item in release['assets'] if item['name'] == sys.argv[2])
    url = asset['browser_download_url']
    if not isinstance(version, str) or not version or '\n' in version:
        raise ValueError('invalid version')
    if not isinstance(url, str) or not url.startswith('https://github.com/zhboner/realm/releases/download/') or '\n' in url:
        raise ValueError('invalid download URL')
    with open(sys.argv[3], 'w', encoding='utf-8') as f:
        f.write(version + '\n' + url + '\n')
except (OSError, ValueError, KeyError, TypeError, StopIteration) as exc:
    print(f'最新版本信息无效或缺少对应架构的安装包: {exc}', file=sys.stderr)
    sys.exit(1)
PY
  then rm -rf "$tmp"; return 1; fi
  { IFS= read -r version; IFS= read -r url; } < "$tmp/metadata"
  echo "正在下载 Realm 最新稳定版：$version ($arch)"
  if ! curl -fL --retry 3 -o "$tmp/realm.tar.gz" "$url" || ! tar -xzf "$tmp/realm.tar.gz" -C "$tmp" realm || [[ ! -f $tmp/realm ]]; then
    rm -rf "$tmp"; die '下载或解压失败。'; return
  fi
  mkdir -p "$DIR" || return
  install -m 755 "$tmp/realm" "$BIN" || return
  rm -rf "$tmp"
  if [[ ! -e $CONFIG ]]; then printf '[network]\nno_tcp = false\nuse_udp = true\n' > "$CONFIG"; fi
  cat > "$UNIT" <<EOF
[Unit]
Description=Realm forwarding (realm-manager)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN -c $CONFIG
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || return
  echo '安装完成。请先添加转发规则，再启动服务。'
}

list_rules() {
  installed || return
  python3 - "$CONFIG" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    print('查看规则需要 Python 3.11 或更高版本。', file=sys.stderr); sys.exit(1)
with open(sys.argv[1], 'rb') as f: data = tomllib.load(f)
for i, rule in enumerate(data.get('endpoints', []), 1):
    print(f"{i}. {rule.get('listen', '?')} -> {rule.get('remote', '?')}")
if not data.get('endpoints'): print('暂无规则。')
PY
}

apply_config() {
  local candidate=$1 backup
  backup=$(mktemp "$DIR/config.backup.XXXXXX") || return
  cp "$CONFIG" "$backup" || return
  cp "$candidate" "$CONFIG" || return
  if systemctl is-active --quiet realm-manager; then
    if ! systemctl restart realm-manager; then
      cp "$backup" "$CONFIG"
      systemctl restart realm-manager || echo '恢复服务失败，请检查 systemctl status realm-manager。' >&2
      rm -f "$backup" "$candidate"
      die '重启失败，已恢复原配置。'; return
    fi
  fi
  rm -f "$backup" "$candidate"
  echo '规则已保存。'
}

add_rule() {
  need_root && installed || return
  local lp host rp candidate
  read -r -p '监听端口: ' lp || return
  port_ok "$lp" || { die '监听端口应为 1-65535。'; return; }
  read -r -p '目标 IP 或域名（IPv6 无需方括号）: ' host || return
  [[ $host =~ ^[a-zA-Z0-9.:_-]+$ ]] || { die '目标地址格式无效。'; return; }
  read -r -p '目标端口: ' rp || return
  port_ok "$rp" || { die '目标端口应为 1-65535。'; return; }
  if ! python3 - "$host" <<'PY'
import ipaddress, re, sys
host = sys.argv[1]
try:
    ipaddress.ip_address(host)
except ValueError:
    if len(host) > 253 or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', part) for part in host.rstrip('.').split('.')):
        print('目标 IP 或域名无效。', file=sys.stderr); sys.exit(1)
PY
  then return 1; fi
  [[ $host == *:* ]] && host="[$host]"
  if ! python3 - "$CONFIG" "$lp" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as f: config = tomllib.load(f)
if any(str(rule.get('listen', '')).rsplit(':', 1)[-1] == str(int(sys.argv[2])) for rule in config.get('endpoints', [])):
    print('该监听端口已存在。', file=sys.stderr); sys.exit(1)
PY
  then return 1; fi
  candidate=$(mktemp "$DIR/config.new.XXXXXX") || return
  cp "$CONFIG" "$candidate"
  # IPv4 默认监听适用于没有启用 IPv6 的 Debian 服务器。
  printf '\n[[endpoints]]\nlisten = "0.0.0.0:%s"\nremote = "%s:%s"\n' "$((10#$lp))" "$host" "$((10#$rp))" >> "$candidate"
  apply_config "$candidate"
}

start_service() {
  installed || return
  if ! python3 - "$CONFIG" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as f: config = tomllib.load(f)
if not config.get('endpoints'):
    print('请先添加至少一条转发规则，再启动服务。', file=sys.stderr); sys.exit(1)
PY
  then return 1; fi
  if ! systemctl enable --now realm-manager; then
    die '服务启动失败，请选择查看日志，检查监听端口是否被占用。'; return
  fi
  if systemctl is-active --quiet realm-manager; then
    echo '服务已启动，并设置开机自启。'
  else
    die '服务未正常运行，请查看日志。'
  fi
}

restart_schedule() {
  installed || return
  local choice hour
  echo '1) 设置每天定时重启  2) 取消定时重启  0) 返回'
  read -r -p '请选择: ' choice || return
  case $choice in
    1)
      read -r -p '每天几点重启（0-23）: ' hour || return
      [[ $hour =~ ^[0-9]{1,2}$ ]] && (( 10#$hour <= 23 )) || { die '请输入 0-23 之间的小时。'; return; }
      hour=$((10#$hour))
      cat > "$TIMER_SERVICE" <<'EOF'
[Unit]
Description=Restart realm-manager if running
[Service]
Type=oneshot
ExecStart=/bin/systemctl try-restart realm-manager.service
EOF
      cat > "$TIMER" <<EOF
[Unit]
Description=Daily realm-manager restart
[Timer]
OnCalendar=*-*-* $hour:00:00
Persistent=true
Unit=realm-manager-restart.service
[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload && systemctl enable realm-manager-restart.timer && systemctl restart realm-manager-restart.timer || { die '设置定时任务失败。'; return; }
      echo "已设置每天 $hour:00 重启运行中的服务。";;
    2)
      systemctl disable --now realm-manager-restart.timer 2>/dev/null || true
      rm -f "$TIMER" "$TIMER_SERVICE"
      systemctl daemon-reload
      echo '已取消定时任务。';;
    0) return;; *) die '无效选项。';;
  esac
}

delete_rule() {
  need_root && installed || return
  list_rules || return
  local n candidate
  read -r -p '要删除的规则序号（回车取消）: ' n || return
  [[ -z $n ]] && return
  [[ $n =~ ^[1-9][0-9]*$ ]] || { die '请输入有效序号。'; return; }
  candidate=$(mktemp "$DIR/config.new.XXXXXX") || return
  if ! python3 - "$CONFIG" "$candidate" "$n" <<'PY'
import re, sys
src, dst, num = sys.argv[1], sys.argv[2], int(sys.argv[3])
text = open(src, encoding='utf-8').read()
starts = list(re.finditer(r'(?m)^[ \t]*\[\[endpoints\]\][ \t]*$', text))
if num > len(starts): print('序号超出范围。', file=sys.stderr); sys.exit(1)
start = starts[num-1].start()
# 下一个 TOML 表开始时停止，避免删除后续其他配置。
end_match = re.search(r'(?m)^[ \t]*\[', text[starts[num-1].end():])
end = starts[num-1].end() + end_match.start() if end_match else len(text)
open(dst, 'w', encoding='utf-8').write(text[:start] + text[end:])
PY
  then rm -f "$candidate"; return 1; fi
  apply_config "$candidate"
}

uninstall() {
  need_root || return
  local answer
  echo "将移除服务、程序和配置：$DIR"
  read -r -p '输入 yes 确认卸载: ' answer || return
  [[ $answer == yes ]] || { echo '已取消。'; return; }
  systemctl disable --now realm-manager-restart.timer 2>/dev/null || true
  rm -f "$TIMER" "$TIMER_SERVICE"
  systemctl disable --now realm-manager.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  rm -rf -- "$DIR"
  echo '已卸载。'
}

main() {
  check_environment || return 1
  while :; do
    printf '\n========== Realm 转发管理（Debian）==========\n'
    if [[ -x $BIN ]]; then printf '安装状态：已安装\n'; else printf '安装状态：未安装\n'; fi
    if systemctl is-active --quiet realm-manager; then printf '服务状态：运行中\n'; else printf '服务状态：未运行\n'; fi
    printf '\n1) 安装最新稳定版   2) 添加规则   3) 查看规则   4) 删除规则\n5) 启动并开机自启   6) 停止服务   7) 重启服务   8) 服务状态\n9) 卸载 Realm      10) 定时重启  11) 查看日志   0) 退出\n'
    read -r -p '请选择: ' choice || break
    case $choice in
      1) install_realm;; 2) add_rule;; 3) list_rules;; 4) delete_rule;;
      5) start_service;;
      6) need_root && installed && systemctl stop realm-manager;;
      7) need_root && installed && systemctl restart realm-manager;;
      8) systemctl status realm-manager --no-pager || true;;
      9) uninstall;; 10) restart_schedule;;
      11) journalctl -u realm-manager -n 80 --no-pager || true;;
      0) break;; *) echo '无效选项。';;
    esac
  done
}
main "$@"
