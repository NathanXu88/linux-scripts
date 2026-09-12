#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Debian Fail2ban SSH Protection Installer v2
#
# 支持：
#   Debian 11 / 12 / 13
#
# 防护策略：
#   10 分钟内 SSH 登录失败 5 次
#   -> 永久封禁该 IP
#
# 防火墙：
#   nftables
#   封禁该 IP 的所有 TCP / UDP 端口
#
# 可选管理 IP 白名单：
#   ADMIN_IP="1.2.3.4"
#
# ============================================================


# ------------------------------------------------------------
# 基础配置
# ------------------------------------------------------------

MAXRETRY=5
FINDTIME="10m"
BANTIME="-1"

CONFIG_FILE="/etc/fail2ban/jail.d/sshd.local"

# 可以通过环境变量指定自己的管理 IP
#
# IPv4:
# ADMIN_IP="1.2.3.4"
#
# IPv4 CIDR:
# ADMIN_IP="1.2.3.0/24"
#
# IPv6:
# ADMIN_IP="2001:db8::1"
#
ADMIN_IP="${ADMIN_IP:-}"


# ------------------------------------------------------------
# 回滚状态
# ------------------------------------------------------------

ROLLBACK_ARMED=0
CONFIG_EXISTED=0
BACKUP_FILE=""

F2B_WAS_ACTIVE=0
F2B_WAS_ENABLED=0


# ------------------------------------------------------------
# 输出函数
# ------------------------------------------------------------

info() {
    printf '\n[INFO] %s\n' "$*"
}

success() {
    printf '\n[OK] %s\n' "$*"
}

warn() {
    printf '\n[WARNING] %s\n' "$*"
}

error() {
    printf '\n[ERROR] %s\n' "$*" >&2
}


# ------------------------------------------------------------
# 回滚函数
# ------------------------------------------------------------

rollback() {

    set +e

    warn "检测到安装或配置失败，正在回滚 Fail2ban 配置..."

    # 如果以前存在配置，则恢复备份
    if [ "${CONFIG_EXISTED}" -eq 1 ] \
        && [ -n "${BACKUP_FILE}" ] \
        && [ -f "${BACKUP_FILE}" ]; then

        cp -a "${BACKUP_FILE}" "${CONFIG_FILE}"

        warn "已经恢复原来的配置：${CONFIG_FILE}"

    else

        # 原来不存在配置，则删除此次创建的配置
        rm -f "${CONFIG_FILE}"

        warn "已经删除此次创建的配置：${CONFIG_FILE}"

    fi


    # 检查恢复后的配置
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client -t >/dev/null 2>&1 || true
    fi


    # 恢复 Fail2ban 原来的运行状态
    if command -v systemctl >/dev/null 2>&1; then

        if [ "${F2B_WAS_ACTIVE}" -eq 1 ]; then

            systemctl restart fail2ban >/dev/null 2>&1 || true

        else

            systemctl stop fail2ban >/dev/null 2>&1 || true

        fi


        # 恢复原来的开机启动状态
        if [ "${F2B_WAS_ENABLED}" -eq 1 ]; then

            systemctl enable fail2ban >/dev/null 2>&1 || true

        else

            systemctl disable fail2ban >/dev/null 2>&1 || true

        fi

    fi


    warn "回滚完成。"

    warn "已经安装的软件包不会被自动卸载。"
}


# ------------------------------------------------------------
# 错误处理
# ------------------------------------------------------------

on_error() {

    local rc=$?
    local line="${1:-unknown}"

    trap - ERR

    error "脚本在第 ${line} 行执行失败。"
    error "退出码：${rc}"

    if [ "${ROLLBACK_ARMED}" -eq 1 ]; then
        rollback
    fi

    exit "${rc}"
}


trap 'on_error "${LINENO}"' ERR


# ------------------------------------------------------------
# 检查 root 权限
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then

    error "必须使用 root 权限运行此脚本。"

    echo
    echo "例如："
    echo
    echo "sudo bash install-fail2ban.sh"

    exit 1
fi


# ------------------------------------------------------------
# 检查系统
# ------------------------------------------------------------

if [ ! -r /etc/os-release ]; then

    error "无法读取 /etc/os-release。"

    exit 1
fi


. /etc/os-release


if [ "${ID:-}" != "debian" ]; then

    error "此脚本仅支持 Debian。"
    error "当前系统 ID：${ID:-unknown}"

    exit 1
fi


DEBIAN_MAJOR="${VERSION_ID%%.*}"


case "${DEBIAN_MAJOR}" in

    11|12|13)
        ;;

    *)
        error "此版本仅验证 Debian 11 / 12 / 13。"
        error "当前 VERSION_ID=${VERSION_ID:-unknown}"
        exit 1
        ;;

esac


# ------------------------------------------------------------
# 检查 systemd
# ------------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then

    error "系统不存在 systemctl。"

    exit 1
fi


if [ ! -d /run/systemd/system ]; then

    error "systemd 当前没有作为 init 系统运行。"

    exit 1
fi


# ------------------------------------------------------------
# 保存 Fail2ban 当前状态
# ------------------------------------------------------------

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    F2B_WAS_ACTIVE=1
fi


if systemctl is-enabled --quiet fail2ban 2>/dev/null; then
    F2B_WAS_ENABLED=1
fi


# ------------------------------------------------------------
# 显示基本信息
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Debian Fail2ban SSH Protection Installer v2"
echo "============================================================"

echo "系统       : ${PRETTY_NAME:-Debian}"
echo "主机名     : $(hostname)"

echo
echo "Fail2ban 防护规则："
echo
echo "  10 分钟内 SSH 登录失败 5 次"
echo "  永久封禁攻击 IP"
echo "  封禁该 IP 的所有 TCP / UDP 端口"
echo
echo "防火墙：nftables"

echo
echo "============================================================"
echo


# ------------------------------------------------------------
# 更新软件源
# ------------------------------------------------------------

info "更新 Debian 软件包索引..."

apt-get update


# ------------------------------------------------------------
# 安装组件
# ------------------------------------------------------------

info "安装 Fail2ban、nftables 和 systemd Python 支持..."

DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
    fail2ban \
    nftables \
    python3-systemd


# ------------------------------------------------------------
# 检查必要命令
# ------------------------------------------------------------

for cmd in fail2ban-client nft python3; do

    if ! command -v "${cmd}" >/dev/null 2>&1; then

        error "安装完成后仍然找不到命令：${cmd}"

        exit 1

    fi

done


# ------------------------------------------------------------
# 检查 OpenSSH Server
# ------------------------------------------------------------

if ! command -v sshd >/dev/null 2>&1 \
    && [ ! -x /usr/sbin/sshd ]; then

    error "没有检测到 OpenSSH Server (sshd)。"

    error "此脚本不会自动安装 SSH Server。"

    exit 1
fi


SSHD_BIN="$(command -v sshd 2>/dev/null || true)"


if [ -z "${SSHD_BIN}" ]; then
    SSHD_BIN="/usr/sbin/sshd"
fi


# ------------------------------------------------------------
# 检测 SSH 端口
#
# 注意：
# 实际封禁使用 allports，
# 所以即使 SSH 使用非 22 端口，也不会影响封禁。
# ------------------------------------------------------------

SSH_PORTS="$(
    "${SSHD_BIN}" -T 2>/dev/null \
    | awk '$1 == "port" {print $2}' \
    | sort -nu \
    | paste -sd, - \
    || true
)"


if [ -z "${SSH_PORTS}" ]; then
    SSH_PORTS="unknown"
fi


info "检测到 SSH 配置端口：${SSH_PORTS}"


# ------------------------------------------------------------
# IP / CIDR 验证
# ------------------------------------------------------------

validate_ip_or_cidr() {

    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
PY

}


# ------------------------------------------------------------
# 默认白名单
# ------------------------------------------------------------

IGNORE_IP="127.0.0.1/8 ::1"


# ------------------------------------------------------------
# 尝试检测当前 SSH 客户端
# ------------------------------------------------------------

CURRENT_SSH_IP=""


if [ -n "${SSH_CONNECTION:-}" ]; then

    CURRENT_SSH_IP="${SSH_CONNECTION%% *}"


    if validate_ip_or_cidr "${CURRENT_SSH_IP}"; then

        IGNORE_IP="${IGNORE_IP} ${CURRENT_SSH_IP}"

        success "当前 SSH 客户端 IP 已加入白名单：${CURRENT_SSH_IP}"

    else

        CURRENT_SSH_IP=""

    fi

fi


# ------------------------------------------------------------
# 检查 ADMIN_IP
# ------------------------------------------------------------

if [ -n "${ADMIN_IP}" ]; then

    if ! validate_ip_or_cidr "${ADMIN_IP}"; then

        error "ADMIN_IP 格式错误：${ADMIN_IP}"

        error "只允许 IPv4、IPv6 或 CIDR。"

        exit 1
    fi


    # 防止重复
    case " ${IGNORE_IP} " in

        *" ${ADMIN_IP} "*)
            ;;

        *)
            IGNORE_IP="${IGNORE_IP} ${ADMIN_IP}"
            ;;

    esac


    success "管理 IP 已加入白名单：${ADMIN_IP}"

fi


info "最终白名单：${IGNORE_IP}"


# ------------------------------------------------------------
# 创建配置目录
# ------------------------------------------------------------

mkdir -p /etc/fail2ban/jail.d


# ------------------------------------------------------------
# 备份原配置
# ------------------------------------------------------------

if [ -f "${CONFIG_FILE}" ]; then

    CONFIG_EXISTED=1

    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"


    cp -a \
        "${CONFIG_FILE}" \
        "${BACKUP_FILE}"


    success "原来的 Fail2ban 配置已经备份："

    echo
    echo "${BACKUP_FILE}"

fi


# ------------------------------------------------------------
# 写入 Fail2ban SSH 配置
# ------------------------------------------------------------

info "写入 Fail2ban SSH 防护配置..."


cat > "${CONFIG_FILE}" <<EOF

# ============================================================
# Managed by install-fail2ban.sh
#
# Debian Fail2ban SSH protection
# ============================================================


[sshd]


# 启用 SSH 防护
enabled = true


# 使用 Fail2ban 官方 SSH 过滤器
filter = sshd


# Debian 使用 systemd journal
backend = systemd


# 不使用 DNS 解析攻击来源
usedns = no


# 永远不会被封禁的地址
ignoreip = ${IGNORE_IP}


# 10 分钟统计窗口
findtime = ${FINDTIME}


# 失败 5 次
maxretry = ${MAXRETRY}


# -1 = 永久封禁
bantime = ${BANTIME}


# TCP + UDP
protocol = tcp,udp


# 使用 nftables
#
# allports 表示：
# 一旦 SSH 登录攻击触发封禁，
# 该来源 IP 的所有 TCP / UDP 端口都会被阻止。
#
# 因此 SSH 即使使用 22、2222 或其他端口也没有影响。
#
banaction = nftables[type=allports]

EOF


chmod 0644 "${CONFIG_FILE}"


# 从这里开始，如果发生错误就自动回滚
ROLLBACK_ARMED=1


# ------------------------------------------------------------
# 检查配置
# ------------------------------------------------------------

info "检查 Fail2ban 配置..."


if ! fail2ban-client -t; then

    error "Fail2ban 配置检查失败。"

    false

fi


success "Fail2ban 配置检查通过。"


# ------------------------------------------------------------
# 设置开机启动
# ------------------------------------------------------------

info "设置 Fail2ban 开机自动启动..."


systemctl enable fail2ban >/dev/null


# ------------------------------------------------------------
# 重启 Fail2ban
# ------------------------------------------------------------

info "启动 / 重启 Fail2ban..."


systemctl restart fail2ban


sleep 2


# ------------------------------------------------------------
# 检查服务状态
# ------------------------------------------------------------

if ! systemctl is-active --quiet fail2ban; then

    error "Fail2ban 服务没有正常运行。"

    systemctl status fail2ban --no-pager || true

    false
fi


success "Fail2ban 服务正在运行。"


# ------------------------------------------------------------
# 检查 sshd jail
# ------------------------------------------------------------

if ! fail2ban-client status sshd >/dev/null 2>&1; then

    error "sshd jail 没有正常启动。"

    fail2ban-client status || true

    false
fi


success "sshd jail 正常运行。"


# ------------------------------------------------------------
# 验证实际运行参数
# ------------------------------------------------------------

info "验证实际生效的 Fail2ban 参数..."


ACTUAL_MAXRETRY="$(
    fail2ban-client get sshd maxretry \
    | tr -d '[:space:]'
)"


ACTUAL_FINDTIME="$(
    fail2ban-client get sshd findtime \
    | tr -d '[:space:]'
)"


ACTUAL_BANTIME="$(
    fail2ban-client get sshd bantime \
    | tr -d '[:space:]'
)"


# maxretry
if [ "${ACTUAL_MAXRETRY}" != "5" ]; then

    error "maxretry 验证失败。"
    error "期望：5"
    error "实际：${ACTUAL_MAXRETRY}"

    false
fi


# findtime
if [ "${ACTUAL_FINDTIME}" != "600" ]; then

    error "findtime 验证失败。"
    error "期望：600 秒"
    error "实际：${ACTUAL_FINDTIME}"

    false
fi


# bantime
if [ "${ACTUAL_BANTIME}" != "-1" ]; then

    error "bantime 验证失败。"
    error "期望：-1"
    error "实际：${ACTUAL_BANTIME}"

    false
fi


success "所有参数验证通过。"


# ------------------------------------------------------------
# 配置成功，不再需要回滚
# ------------------------------------------------------------

ROLLBACK_ARMED=0


# ------------------------------------------------------------
# 最终结果
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Fail2ban 安装完成"
echo "============================================================"

echo
echo "系统："
echo
echo "  Debian ${VERSION_ID}"


echo
echo "SSH 配置端口："
echo
echo "  ${SSH_PORTS}"


echo
echo "防护规则："
echo
echo "  10 分钟内登录失败 5 次"
echo "  永久封禁攻击 IP"


echo
echo "封禁范围："
echo
echo "  该 IP 的全部 TCP / UDP 端口"


echo
echo "实际 maxretry："
echo
echo "  ${ACTUAL_MAXRETRY}"


echo
echo "实际 findtime："
echo
echo "  ${ACTUAL_FINDTIME} 秒"


echo
echo "实际 bantime："
echo
echo "  ${ACTUAL_BANTIME}（永久）"


echo
echo "白名单："
echo
echo "  ${IGNORE_IP}"


echo
echo "配置文件："
echo
echo "  ${CONFIG_FILE}"


echo
echo "============================================================"
echo


# ------------------------------------------------------------
# 显示当前状态
# ------------------------------------------------------------

fail2ban-client status sshd


# ------------------------------------------------------------
# 常用命令
# ------------------------------------------------------------

echo
echo "============================================================"
echo " 常用管理命令"
echo "============================================================"


echo
echo "查看 Fail2ban："
echo
echo "  sudo fail2ban-client status"


echo
echo "查看 SSH 防护："
echo
echo "  sudo fail2ban-client status sshd"


echo
echo "查看被封 IP："
echo
echo "  sudo fail2ban-client get sshd banip"


echo
echo "手动解封 IP："
echo
echo "  sudo fail2ban-client set sshd unbanip 1.2.3.4"


echo
echo "手动封禁 IP："
echo
echo "  sudo fail2ban-client set sshd banip 1.2.3.4"


echo
echo "实时查看 Fail2ban 日志："
echo
echo "  sudo journalctl -u fail2ban -f"


echo
echo "查看 nftables："
echo
echo "  sudo nft list ruleset"


echo
echo "============================================================"
echo


# ------------------------------------------------------------
# 没有管理 IP 时提醒
# ------------------------------------------------------------

if [ -z "${ADMIN_IP}" ] \
    && [ -z "${CURRENT_SSH_IP}" ]; then

    warn "没有检测到你的管理 IP。"

    echo
    echo "如果你有固定管理 IP，建议下一次执行时指定："
    echo
    echo 'ADMIN_IP="你的IP"'
    echo

fi


success "Fail2ban SSH 防护配置全部完成。"
