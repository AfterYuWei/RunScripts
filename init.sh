#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# VPS 开荒脚本
#
# 功能：
#   1. 允许 root SSH 登录
#   2. SSH 端口修改为 32222
#   3. 安装并启用 UFW
#   4. 开放 TCP: 32222 / 80 / 443
#   5. 默认拒绝其他入站连接
#   6. 兼容常见 Debian / RHEL 系发行版
#
# 支持：
#   Debian
#   Ubuntu
#   CentOS
#   RHEL
#   Rocky Linux
#   AlmaLinux
#   Fedora
# ============================================================

SSH_PORT="32222"
SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ------------------------------------------------------------
# 必须 root 执行
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 用户运行此脚本。"
    exit 1
fi

# ------------------------------------------------------------
# 检查系统
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "无法识别当前 Linux 系统。"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

DISTRO="${ID:-unknown}"
DISTRO_LIKE="${ID_LIKE:-}"

info "系统: ${PRETTY_NAME:-$DISTRO}"

# ------------------------------------------------------------
# 包管理器
# ------------------------------------------------------------

install_apt() {
    info "更新软件包索引..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y

    info "安装 OpenSSH、UFW 等组件..."
    apt-get install -y \
        openssh-server \
        ufw \
        curl \
        ca-certificates
}

install_dnf() {
    info "安装 OpenSSH、UFW 等组件..."

    dnf install -y \
        openssh-server \
        curl \
        ca-certificates || true

    # Fedora 通常直接有 ufw
    if ! dnf install -y ufw; then
        warn "默认仓库未找到 UFW，尝试安装 EPEL..."

        dnf install -y epel-release || true
        dnf makecache -y || true
        dnf install -y ufw
    fi
}

install_yum() {
    info "安装 OpenSSH、UFW 等组件..."

    yum install -y \
        openssh-server \
        curl \
        ca-certificates || true

    if ! yum install -y ufw; then
        warn "默认仓库未找到 UFW，尝试安装 EPEL..."

        yum install -y epel-release || true
        yum makecache -y || true
        yum install -y ufw
    fi
}

if command -v apt-get >/dev/null 2>&1; then
    install_apt

elif command -v dnf >/dev/null 2>&1; then
    install_dnf

elif command -v yum >/dev/null 2>&1; then
    install_yum

else
    error "不支持当前系统的软件包管理器。"
    exit 1
fi

# ------------------------------------------------------------
# 查找 sshd
# ------------------------------------------------------------

SSHD_BIN="$(command -v sshd || true)"

if [[ -z "$SSHD_BIN" ]]; then
    for path in /usr/sbin/sshd /sbin/sshd; do
        if [[ -x "$path" ]]; then
            SSHD_BIN="$path"
            break
        fi
    done
fi

if [[ -z "$SSHD_BIN" ]]; then
    error "没有找到 sshd。"
    exit 1
fi

success "sshd: $SSHD_BIN"

# ------------------------------------------------------------
# 获取当前 SSH 端口
# ------------------------------------------------------------

OLD_SSH_PORT="$(
    "$SSHD_BIN" -T 2>/dev/null |
        awk '$1 == "port" {print $2; exit}'
)"

if [[ -z "$OLD_SSH_PORT" ]]; then
    OLD_SSH_PORT="22"
fi

info "当前 SSH 端口: ${OLD_SSH_PORT}"
info "新 SSH 端口: ${SSH_PORT}"

# ------------------------------------------------------------
# SSH 配置备份
# ------------------------------------------------------------

mkdir -p "$BACKUP_DIR"

cp -a "$SSH_CONFIG" "$BACKUP_DIR/sshd_config"

if [[ -d /etc/ssh/sshd_config.d ]]; then
    cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/" 2>/dev/null || true
fi

success "SSH 配置已备份到: $BACKUP_DIR"

# ------------------------------------------------------------
# UFW 配置
#
# 先开放旧 SSH + 新 SSH，防止修改过程中把自己锁死。
# SSH 成功重启后再删除旧端口。
# ------------------------------------------------------------

info "配置 UFW..."

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# 临时保留旧 SSH
ufw allow "${OLD_SSH_PORT}/tcp"

# 新 SSH
ufw allow "${SSH_PORT}/tcp"

# HTTP / HTTPS
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable

success "UFW 已启动"

# ------------------------------------------------------------
# SELinux
#
# RHEL / CentOS / Rocky / AlmaLinux 等开启 SELinux 时，
# sshd 默认无法监听 32222，需要添加 ssh_port_t。
# ------------------------------------------------------------

if command -v getenforce >/dev/null 2>&1; then

    SELINUX_STATUS="$(getenforce 2>/dev/null || true)"

    info "SELinux 状态: ${SELINUX_STATUS}"

    if [[ "$SELINUX_STATUS" == "Enforcing" || "$SELINUX_STATUS" == "Permissive" ]]; then

        info "配置 SELinux SSH 端口..."

        if ! command -v semanage >/dev/null 2>&1; then

            if command -v dnf >/dev/null 2>&1; then
                dnf install -y policycoreutils-python-utils || true
            elif command -v yum >/dev/null 2>&1; then
                yum install -y policycoreutils-python || \
                    yum install -y policycoreutils-python-utils || true
            fi

        fi

        if command -v semanage >/dev/null 2>&1; then

            if semanage port -l |
                awk '$1 == "ssh_port_t" {print}' |
                grep -qw "${SSH_PORT}"; then

                success "SELinux 已允许 SSH ${SSH_PORT}"

            else
                semanage port -a \
                    -t ssh_port_t \
                    -p tcp \
                    "${SSH_PORT}" 2>/dev/null ||
                semanage port -m \
                    -t ssh_port_t \
                    -p tcp \
                    "${SSH_PORT}"

                success "SELinux 已放行 SSH ${SSH_PORT}"
            fi

        else
            warn "无法找到 semanage，SELinux 可能阻止 SSH 使用 ${SSH_PORT}"
        fi

    fi
fi

# ------------------------------------------------------------
# 修改 SSH 配置
# ------------------------------------------------------------

info "修改 SSH 配置..."

# Port
if grep -Eq '^[[:space:]]*#?[[:space:]]*Port[[:space:]]+' "$SSH_CONFIG"; then

    sed -ri \
        "s/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" \
        "$SSH_CONFIG"

else
    echo "Port ${SSH_PORT}" >> "$SSH_CONFIG"
fi

# PermitRootLogin
if grep -Eq '^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]+' "$SSH_CONFIG"; then

    sed -ri \
        's/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin yes/' \
        "$SSH_CONFIG"

else
    echo "PermitRootLogin yes" >> "$SSH_CONFIG"
fi

# ------------------------------------------------------------
# 检查 sshd 配置
# ------------------------------------------------------------

info "检查 SSH 配置..."

if ! "$SSHD_BIN" -t; then

    error "SSH 配置检查失败！"
    warn "正在恢复 SSH 配置..."

    cp -af "$BACKUP_DIR/sshd_config" "$SSH_CONFIG"

    # 确保旧端口可以继续登录
    ufw allow "${OLD_SSH_PORT}/tcp" || true

    error "已恢复原 SSH 配置。"
    exit 1
fi

success "SSH 配置检查通过"

# ------------------------------------------------------------
# 处理 SSH 服务
# ------------------------------------------------------------

restart_ssh() {

    if systemctl list-unit-files ssh.service >/dev/null 2>&1 &&
       systemctl list-unit-files ssh.service |
           grep -q '^ssh.service'; then

        systemctl restart ssh

    elif systemctl list-unit-files sshd.service >/dev/null 2>&1 &&
         systemctl list-unit-files sshd.service |
             grep -q '^sshd.service'; then

        systemctl restart sshd

    elif systemctl restart ssh 2>/dev/null; then
        true

    elif systemctl restart sshd 2>/dev/null; then
        true

    else
        return 1
    fi
}

info "重启 SSH 服务..."

if ! restart_ssh; then

    error "SSH 服务重启失败。"
    warn "正在恢复配置..."

    cp -af "$BACKUP_DIR/sshd_config" "$SSH_CONFIG"

    restart_ssh || true

    ufw allow "${OLD_SSH_PORT}/tcp" || true

    error "初始化失败，已尝试恢复原 SSH 配置。"
    exit 1
fi

# Ubuntu 部分版本可能启用了 ssh.socket
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket || true
fi

success "SSH 服务已重启"

# ------------------------------------------------------------
# 检查新端口是否监听
# ------------------------------------------------------------

sleep 1

if command -v ss >/dev/null 2>&1; then

    if ss -lnt |
        awk '{print $4}' |
        grep -Eq "[:.]${SSH_PORT}$"; then

        success "SSH 已监听 ${SSH_PORT}"

    else
        warn "暂未检测到 ${SSH_PORT} 监听状态。"
        warn "暂时保留旧 SSH 防火墙端口 ${OLD_SSH_PORT}。"

        echo
        ss -lntp 2>/dev/null | grep ssh || true

        exit 1
    fi

fi

# ------------------------------------------------------------
# 确认成功以后关闭旧 SSH 端口
# ------------------------------------------------------------

if [[ "$OLD_SSH_PORT" != "$SSH_PORT" ]]; then

    info "关闭旧 SSH 防火墙端口 ${OLD_SSH_PORT}..."

    ufw --force delete allow "${OLD_SSH_PORT}/tcp" >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------
# 如果存在 firewalld，避免两个防火墙同时管理
# ------------------------------------------------------------

if systemctl is-active --quiet firewalld 2>/dev/null; then

    warn "检测到 firewalld，UFW 与 firewalld 不建议同时运行。"

    systemctl stop firewalld
    systemctl disable firewalld >/dev/null 2>&1 || true

    success "firewalld 已关闭"
fi

# ------------------------------------------------------------
# 最终状态
# ------------------------------------------------------------

echo
echo "============================================================"
echo -e "${GREEN}初始化完成${NC}"
echo "============================================================"
echo
echo "SSH:"
echo "  Port:              ${SSH_PORT}"
echo "  PermitRootLogin:   yes"
echo
echo "UFW:"
ufw status verbose
echo
echo "以后请使用："
echo
echo "  ssh -p ${SSH_PORT} root@服务器IP"
echo
echo "SSH 配置备份："
echo
echo "  ${BACKUP_DIR}"
echo
echo "============================================================"