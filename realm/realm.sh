#!/usr/bin/env bash
# realm 管理工具：仅管理本工具创建的配置及服务。
set -uo pipefail

DIR=/opt/realm-manager
CONFIG=$DIR/config.toml
BIN=$DIR/realm
UNIT=/etc/systemd/system/realm-manager.service
VERSION=v2.9.6

die() { echo "错误：$*" >&2; return 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 或 sudo 运行。'; }
installed() { [[ -x $BIN && -f $CONFIG && -f $UNIT ]] || die '请先安装 realm。'; }
port_ok() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

install_realm() {
  need_root || return
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { die '需要使用 systemd 的 Linux 系统。'; return; }
  for cmd in curl tar python3; do command -v "$cmd" >/dev/null || { die "缺少 $cmd，请先安装。"; return; }; done
  python3 -c 'import tomllib' 2>/dev/null || { die '需要 Python 3.11 或更高版本。'; return; }
  case $(uname -m) in
    x86_64) arch=x86_64;; aarch64|arm64) arch=aarch64;; *) die '仅支持 x86_64 和 aarch64。'; return;;
  esac
  if [[ -e $UNIT || -e $BIN ]]; then die '已存在本工具的安装；为保护现有数据，请先卸载。'; return; fi
  local tmp url
  tmp=$(mktemp -d) || return
  url="https://github.com/zhboner/realm/releases/download/$VERSION/realm-${arch}-unknown-linux-musl.tar.gz"
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
  echo '安装完成。添加规则后选择启动服务。'
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
  [[ $host == *:* ]] && host="[$host]"
  candidate=$(mktemp "$DIR/config.new.XXXXXX") || return
  cp "$CONFIG" "$candidate"
  printf '\n[[endpoints]]\nlisten = "[::]:%s"\nremote = "%s:%s"\n' "$lp" "$host" "$rp" >> "$candidate"
  apply_config "$candidate"
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
  systemctl disable --now realm-manager.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  rm -rf -- "$DIR"
  echo '已卸载。'
}

main() {
  while :; do
    printf '\nRealm 管理\n1) 安装  2) 添加规则  3) 查看规则  4) 删除规则\n5) 启动并开机自启  6) 停止  7) 重启  8) 状态  9) 卸载  0) 退出\n'
    read -r -p '请选择: ' choice || break
    case $choice in
      1) install_realm;; 2) add_rule;; 3) list_rules;; 4) delete_rule;;
      5) need_root && installed && systemctl enable --now realm-manager;;
      6) need_root && installed && systemctl stop realm-manager;;
      7) need_root && installed && systemctl restart realm-manager;;
      8) systemctl status realm-manager --no-pager || true;;
      9) uninstall;; 0) break;; *) echo '无效选项。';;
    esac
  done
}
main "$@"
