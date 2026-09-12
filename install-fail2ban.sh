#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Debian Fail2ban SSH Protection Installer
#
# 功能：
#   - 仅支持 Debian
#   - 自动安装 Fail2ban
#   - 启用 SSH 登录保护
#   - 10 分钟内登录失败 5 次，永久封禁 IP
#   - 自动启用并启动 Fail2ban
#   - 支持设置管理 IP 白名单
#
# 使用：
#   sudo bash install-fail2ban.sh
#
# 添加自己的固定公网 IP 到白名单：
#   sudo ADMIN_IP="1.2.3.4" bash install-fail2ban.sh
#
# ============================================================


# ------------------------------------------------------------
# 基础配置
# ------------------------------------------------------------

MAXRETRY=5
FINDTIME="10m"

# -1 = 永久封禁
BANTIME="-1"

# 默认永远不封 localhost
DEFAULT_IGNORE_IP="127.0.0.1/8 ::1"

# 可选：
# 执行脚本时可以传入自己的管理公网 IP
#
# 例如：
#
# sudo ADMIN_IP="1.2.3.4" bash install-fail2ban.sh
#
ADMIN_IP="${ADMIN_IP:-}"


# ------------------------------------------------------------
# 输出函数
# ------------------------------------------------------------

info() {
    echo
    echo "[INFO] $*"
}

success() {
    echo
    echo "[OK] $*"
}

warning() {
    echo
    echo "[WARNING] $*"
}

error() {
    echo
    echo "[ERROR] $*" >&2
}


# ------------------------------------------------------------
# 异常捕获
# ------------------------------------------------------------

trap 'error "脚本在第 ${LINENO} 行执行失败。"; exit 1' ERR


# ------------------------------------------------------------
# 检查 root 权限
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    error "此脚本必须使用 root 权限运行。"
    echo
    echo "请使用："
    echo
    echo "sudo bash $0"
    echo
    echo "或者："
    echo
    echo "sudo ADMIN_IP=\"你的公网IP\" bash $0"
    exit 1
fi


# ------------------------------------------------------------
# 检查 Debian
# ------------------------------------------------------------

if [ ! -f /etc/debian_version ]; then
    error "没有检测到 Debian 系统。"
    error "此脚本仅用于 Debian。"
    exit 1
fi


# ------------------------------------------------------------
# 显示系统信息
# ------------------------------------------------------------

echo
echo "============================================================"
echo "        Debian Fail2ban SSH Protection Installer"
echo "============================================================"
echo

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "系统       : ${PRETTY_NAME:-Debian}"
fi

echo "主机名     : $(hostname)"
echo "封禁规则   : ${FINDTIME} 内 SSH 失败 ${MAXRETRY} 次"
echo "封禁时间   : 永久"

if [ -n "${ADMIN_IP}" ]; then
    echo "管理白名单 : ${ADMIN_IP}"
else
    echo "管理白名单 : 未指定"
fi

echo


# ------------------------------------------------------------
# 更新软件包索引
# ------------------------------------------------------------

info "更新 Debian 软件包索引..."

apt-get update


# ------------------------------------------------------------
# 安装 Fail2ban
# ------------------------------------------------------------

info "安装 Fail2ban..."

DEBIAN_FRONTEND=noninteractive \
    apt-get install -y fail2ban


# ------------------------------------------------------------
# 确认 fail2ban-client 存在
# ------------------------------------------------------------

if ! command -v fail2ban-client >/dev/null 2>&1; then
    error "Fail2ban 安装失败，找不到 fail2ban-client。"
    exit 1
fi


# ------------------------------------------------------------
# 检查 systemd
# ------------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    error "系统没有找到 systemctl。"
    error "此脚本需要 systemd。"
    exit 1
fi


# ------------------------------------------------------------
# 检查 SSH 服务
# ------------------------------------------------------------

if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
else
    warning "没有检测到 ssh.service 或 sshd.service。"
    warning "Fail2ban 仍会配置 sshd jail，但请确认 SSH Server 已安装。"
    SSH_SERVICE=""
fi


# ------------------------------------------------------------
# 创建配置目录
# ------------------------------------------------------------

info "创建 Fail2ban 配置目录..."

mkdir -p /etc/fail2ban/jail.d


# ------------------------------------------------------------
# 备份已有配置
# ------------------------------------------------------------

CONFIG_FILE="/etc/fail2ban/jail.d/sshd.local"

if [ -f "${CONFIG_FILE}" ]; then

    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"

    info "发现已有配置，正在备份..."

    cp -a "${CONFIG_FILE}" "${BACKUP_FILE}"

    success "旧配置已备份到：${BACKUP_FILE}"
fi


# ------------------------------------------------------------
# 生成 ignoreip
# ------------------------------------------------------------

IGNORE_IP="${DEFAULT_IGNORE_IP}"

if [ -n "${ADMIN_IP}" ]; then
    IGNORE_IP="${IGNORE_IP} ${ADMIN_IP}"
fi


# ------------------------------------------------------------
# 写入 SSH Fail2ban 配置
# ------------------------------------------------------------

info "写入 SSH Fail2ban 防护配置..."

cat > "${CONFIG_FILE}" <<EOF
# ============================================================
# Fail2ban SSH protection
#
# 此文件由 install-fail2ban.sh 自动生成
# ============================================================

[sshd]

# 启用 SSH jail
enabled = true

# Debian 使用 systemd journal
backend = systemd

# 永远不会被封禁的 IP
ignoreip = ${IGNORE_IP}

# 统计登录失败的时间窗口
findtime = ${FINDTIME}

# findtime 时间内允许失败次数
maxretry = ${MAXRETRY}

# -1 代表永久封禁
bantime = ${BANTIME}

EOF


# ------------------------------------------------------------
# 显示生成的配置
# ------------------------------------------------------------

echo
echo "---------------- Fail2ban 配置 ----------------"
cat "${CONFIG_FILE}"
echo "------------------------------------------------"
echo


# ------------------------------------------------------------
# 检查配置语法
# ------------------------------------------------------------

info "检查 Fail2ban 配置..."

if ! fail2ban-client -t; then

    error "Fail2ban 配置检查失败。"

    if [ -n "${BACKUP_FILE:-}" ] && [ -f "${BACKUP_FILE}" ]; then

        warning "正在恢复原来的配置..."

        cp -a "${BACKUP_FILE}" "${CONFIG_FILE}"

    fi

    exit 1
fi

success "Fail2ban 配置检查通过。"


# ------------------------------------------------------------
# 设置开机启动
# ------------------------------------------------------------

info "设置 Fail2ban 开机自动启动..."

systemctl enable fail2ban


# ------------------------------------------------------------
# 重启 Fail2ban
# ------------------------------------------------------------

info "启动 / 重启 Fail2ban..."

systemctl restart fail2ban


# ------------------------------------------------------------
# 确认服务状态
# ------------------------------------------------------------

sleep 2

if ! systemctl is-active --quiet fail2ban; then

    error "Fail2ban 没有正常运行。"

    echo
    systemctl status fail2ban --no-pager || true

    exit 1
fi


success "Fail2ban 正在运行。"


# ------------------------------------------------------------
# 检查 sshd jail
# ------------------------------------------------------------

if ! fail2ban-client status sshd >/dev/null 2>&1; then

    error "sshd jail 没有正常启动。"

    echo
    fail2ban-client status || true

    exit 1
fi


# ------------------------------------------------------------
# 最终状态
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                  安装完成"
echo "============================================================"
echo

echo "规则："
echo
echo "  SSH 登录失败 ${MAXRETRY} 次"
echo "  统计时间窗口：${FINDTIME}"
echo "  封禁时间：永久"
echo

echo "不会被封禁："
echo
echo "  ${IGNORE_IP}"
echo

echo "当前 Fail2ban 状态："
echo

fail2ban-client status

echo
echo "当前 SSH jail 状态："
echo

fail2ban-client status sshd

echo
echo "============================================================"
echo "常用管理命令"
echo "============================================================"
echo

echo "查看 Fail2ban 状态："
echo
echo "  sudo fail2ban-client status"
echo

echo "查看 SSH 封禁状态："
echo
echo "  sudo fail2ban-client status sshd"
echo

echo "手动解封一个 IP："
echo
echo "  sudo fail2ban-client set sshd unbanip 1.2.3.4"
echo

echo "手动封禁一个 IP："
echo
echo "  sudo fail2ban-client set sshd banip 1.2.3.4"
echo

echo "查看 Fail2ban 日志："
echo
echo "  sudo journalctl -u fail2ban"
echo

echo "实时查看日志："
echo
echo "  sudo journalctl -u fail2ban -f"
echo

echo "配置文件："
echo
echo "  ${CONFIG_FILE}"
echo

echo "============================================================"
echo

if [ -z "${ADMIN_IP}" ]; then

    warning "你没有设置 ADMIN_IP 白名单。"

    echo
    echo "如果你的管理公网 IP 是固定的，建议运行时使用："
    echo
    echo '  sudo ADMIN_IP="你的公网IP" bash install-fail2ban.sh'
    echo
    echo "这样可以避免因为自己连续输错 SSH 密码而封掉自己的 IP。"
    echo
fi

success "全部完成。"
