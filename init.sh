#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Universal VPS Init Script
#
# 功能：
#   - 可选允许 Root SSH 登录
#   - 可选修改 SSH 端口
#   - 可选安装并启用 UFW
#   - UFW 自动放行 SSH 端口
#   - 可选放行 80 / 443
#
# 原则：
#   - 不清空 UFW
#   - 不修改 UFW 默认策略
#   - 不删除用户已有规则
#   - 不删除旧 SSH 规则
#   - 不关闭其他防火墙
#   - 不改变发行版原有 SSH 服务模式
# ============================================================


# ============================================================
# 基础配置
# ============================================================

DEFAULT_SSH_PORT="32222"
SSH_CONFIG="/etc/ssh/sshd_config"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'


info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    error "$*"
    exit 1
}


# ============================================================
# 交互输入
#
# 使用 /dev/tty，因此以下两种方式都可以：
#
# bash <(curl ...)
# curl ... | bash
# ============================================================

read_input() {
    local __var="$1"
    local prompt="$2"
    local value=""

    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt" value </dev/tty
    else
        read -r -p "$prompt" value
    fi

    printf -v "$__var" '%s' "$value"
}


ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer=""

    while true; do

        if [[ "$default" == "Y" ]]; then
            read_input answer "${prompt} [Y/n]: "
            answer="${answer:-Y}"
        else
            read_input answer "${prompt} [y/N]: "
            answer="${answer:-N}"
        fi

        case "$answer" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            *)
                warn "请输入 y 或 n"
                ;;
        esac
    done
}


# ============================================================
# Root 检查
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行此脚本"
fi


# ============================================================
# 系统检测
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    die "无法识别当前 Linux 发行版"
fi

# shellcheck disable=SC1091
source /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_NAME="${PRETTY_NAME:-$OS_ID}"

echo
echo "============================================================"
echo -e " ${BOLD}VPS 初始化脚本${NC}"
echo "============================================================"
echo

info "系统: ${OS_NAME}"


# ============================================================
# 包管理器检测
# ============================================================

PKG_MANAGER=""

if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"

elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"

elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"

elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"

elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"

else
    die "暂不支持当前系统的软件包管理器"
fi

info "包管理器: ${PKG_MANAGER}"


# ============================================================
# 软件安装函数
# ============================================================

install_packages() {

    case "$PKG_MANAGER" in

        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y "$@"
            ;;

        dnf)
            dnf install -y "$@"
            ;;

        yum)
            yum install -y "$@"
            ;;

        zypper)
            zypper --non-interactive install "$@"
            ;;

        pacman)
            pacman -Sy --noconfirm --needed "$@"
            ;;

    esac
}


# ============================================================
# OpenSSH 检查
# ============================================================

SSHD_BIN="$(command -v sshd || true)"

if [[ -z "$SSHD_BIN" ]]; then

    for candidate in \
        /usr/sbin/sshd \
        /sbin/sshd \
        /usr/local/sbin/sshd
    do
        if [[ -x "$candidate" ]]; then
            SSHD_BIN="$candidate"
            break
        fi
    done
fi


if [[ -z "$SSHD_BIN" ]]; then

    info "未检测到 OpenSSH Server，尝试安装..."

    case "$PKG_MANAGER" in

        apt)
            install_packages openssh-server
            ;;

        dnf|yum|zypper)
            install_packages openssh-server
            ;;

        pacman)
            install_packages openssh
            ;;

    esac

    SSHD_BIN="$(command -v sshd || true)"

    if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
        SSHD_BIN="/usr/sbin/sshd"
    fi
fi


if [[ -z "$SSHD_BIN" ]]; then
    die "无法找到 sshd"
fi

ok "sshd: ${SSHD_BIN}"


# ============================================================
# 检测当前 SSH 端口
#
# 优先使用当前 SSH 会话实际连接端口。
# ============================================================

CURRENT_SSH_PORT="22"

if [[ -n "${SSH_CONNECTION:-}" ]]; then

    SESSION_PORT="${SSH_CONNECTION##* }"

    if [[ "$SESSION_PORT" =~ ^[0-9]+$ ]]; then
        CURRENT_SSH_PORT="$SESSION_PORT"
    fi

else

    DETECTED_PORT="$(
        "$SSHD_BIN" -T 2>/dev/null \
            | awk '$1 == "port" {print $2; exit}' \
            || true
    )"

    if [[ "$DETECTED_PORT" =~ ^[0-9]+$ ]]; then
        CURRENT_SSH_PORT="$DETECTED_PORT"
    fi

fi

info "当前 SSH 端口: ${CURRENT_SSH_PORT}"


# ============================================================
# 用户选择
# ============================================================

echo

ALLOW_ROOT=false

if ask_yes_no "是否允许 root SSH 登录？" "Y"; then
    ALLOW_ROOT=true
fi


echo

CHANGE_SSH_PORT=false
NEW_SSH_PORT="$CURRENT_SSH_PORT"

if ask_yes_no "是否修改 SSH 端口？" "Y"; then

    CHANGE_SSH_PORT=true

    while true; do

        INPUT_PORT=""

        read_input \
            INPUT_PORT \
            "请输入新的 SSH 端口 [默认 ${DEFAULT_SSH_PORT}]: "

        INPUT_PORT="${INPUT_PORT:-$DEFAULT_SSH_PORT}"


        if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]]; then
            warn "端口必须是数字"
            continue
        fi


        if (( INPUT_PORT < 1 || INPUT_PORT > 65535 )); then
            warn "端口范围必须为 1-65535"
            continue
        fi


        if (( INPUT_PORT == 80 || INPUT_PORT == 443 )); then
            warn "80 / 443 通常用于 HTTP / HTTPS，请选择其他 SSH 端口"
            continue
        fi


        if [[ "$INPUT_PORT" == "$CURRENT_SSH_PORT" ]]; then

            warn "输入端口与当前 SSH 端口相同"

            if ! ask_yes_no "仍然继续？" "N"; then
                continue
            fi
        fi


        # 检查新端口是否被其它服务监听
        if command -v ss >/dev/null 2>&1; then

            if ss -lntH 2>/dev/null \
                | awk '{print $4}' \
                | grep -Eq "[:.]${INPUT_PORT}$"; then

                if [[ "$INPUT_PORT" != "$CURRENT_SSH_PORT" ]]; then

                    warn "端口 ${INPUT_PORT} 当前已经被其他服务监听"

                    if ! ask_yes_no "仍然继续？" "N"; then
                        continue
                    fi
                fi
            fi
        fi

        NEW_SSH_PORT="$INPUT_PORT"
        break

    done

fi


echo

ENABLE_UFW=false
OPEN_WEB_PORTS=false

if ask_yes_no "是否安装并启用 UFW？" "Y"; then

    ENABLE_UFW=true

    echo

    if ask_yes_no "是否开放 80 和 443 端口？" "Y"; then
        OPEN_WEB_PORTS=true
    fi

fi


# ============================================================
# 执行摘要
# ============================================================

echo
echo "============================================================"
echo -e " ${BOLD}配置预览${NC}"
echo "============================================================"
echo

echo -n "Root SSH 登录:      "

if [[ "$ALLOW_ROOT" == true ]]; then
    echo "允许"
else
    echo "禁止"
fi


echo -n "SSH 端口:           "

if [[ "$CHANGE_SSH_PORT" == true ]]; then
    echo "${CURRENT_SSH_PORT} -> ${NEW_SSH_PORT}"
else
    echo "保持 ${CURRENT_SSH_PORT}"
fi


echo -n "UFW:                "

if [[ "$ENABLE_UFW" == true ]]; then
    echo "启用"
else
    echo "不修改"
fi


if [[ "$ENABLE_UFW" == true ]]; then

    echo
    echo "UFW 将新增放行："

    if [[ "$CHANGE_SSH_PORT" == true ]]; then
        echo "  ${NEW_SSH_PORT}/tcp    SSH"
    else
        echo "  ${CURRENT_SSH_PORT}/tcp    SSH"
    fi


    if [[ "$OPEN_WEB_PORTS" == true ]]; then
        echo "  80/tcp              HTTP"
        echo "  443/tcp             HTTPS"
    fi

    echo
    echo "已有 UFW 规则不会被删除或重置。"

fi


echo

if ! ask_yes_no "确认执行以上配置？" "Y"; then
    warn "已取消"
    exit 0
fi


# ============================================================
# SSH 配置备份
# ============================================================

if [[ ! -f "$SSH_CONFIG" ]]; then
    die "找不到 ${SSH_CONFIG}"
fi


BACKUP_DIR="/root/vps-init-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

cp -a \
    "$SSH_CONFIG" \
    "$BACKUP_DIR/sshd_config"


if [[ -d /etc/ssh/sshd_config.d ]]; then

    cp -a \
        /etc/ssh/sshd_config.d \
        "$BACKUP_DIR/sshd_config.d" \
        2>/dev/null || true

fi

ok "SSH 配置已备份到 ${BACKUP_DIR}"


# ============================================================
# 修改 SSH 配置
#
# 把托管配置放在 sshd_config 最顶部。
#
# OpenSSH 对多数选项采用 first value wins，
# 因此放在 Include 之前，可避免 cloud-init / drop-in
# 中已有设置覆盖我们的选择。
# ============================================================

MANAGED_BEGIN="# BEGIN VPS-INIT MANAGED CONFIG"
MANAGED_END="# END VPS-INIT MANAGED CONFIG"

TMP_CONFIG="$(mktemp)"


# 删除之前脚本写入过的 managed block
awk \
    -v begin="$MANAGED_BEGIN" \
    -v end="$MANAGED_END" \
'
$0 == begin {
    skip=1
    next
}

$0 == end {
    skip=0
    next
}

!skip {
    print
}
' \
"$SSH_CONFIG" \
> "$TMP_CONFIG"


{
    echo "$MANAGED_BEGIN"

    if [[ "$ALLOW_ROOT" == true ]]; then
        echo "PermitRootLogin yes"
    else
        echo "PermitRootLogin no"
    fi

    if [[ "$CHANGE_SSH_PORT" == true ]]; then
        echo "Port ${NEW_SSH_PORT}"
    fi

    echo "$MANAGED_END"
    echo

    cat "$TMP_CONFIG"

} > "${SSH_CONFIG}.new"


rm -f "$TMP_CONFIG"

chmod --reference="$SSH_CONFIG" "${SSH_CONFIG}.new" 2>/dev/null || true
chown --reference="$SSH_CONFIG" "${SSH_CONFIG}.new" 2>/dev/null || true

mv "${SSH_CONFIG}.new" "$SSH_CONFIG"


# ============================================================
# SELinux
# ============================================================

if [[ "$CHANGE_SSH_PORT" == true ]] \
    && command -v getenforce >/dev/null 2>&1; then

    SELINUX_STATE="$(getenforce 2>/dev/null || true)"

    if [[ "$SELINUX_STATE" == "Enforcing" \
       || "$SELINUX_STATE" == "Permissive" ]]; then

        info "检测到 SELinux: ${SELINUX_STATE}"


        if ! command -v semanage >/dev/null 2>&1; then

            info "安装 SELinux 管理工具..."

            case "$PKG_MANAGER" in

                dnf)
                    dnf install -y \
                        policycoreutils-python-utils \
                        || true
                    ;;

                yum)
                    yum install -y \
                        policycoreutils-python-utils \
                        || yum install -y \
                            policycoreutils-python \
                        || true
                    ;;

            esac
        fi


        if command -v semanage >/dev/null 2>&1; then

            if semanage port -l 2>/dev/null \
                | awk '$1 == "ssh_port_t" {print}' \
                | grep -qw "$NEW_SSH_PORT"; then

                ok "SELinux 已允许 SSH 端口 ${NEW_SSH_PORT}"

            else

                semanage port \
                    -a \
                    -t ssh_port_t \
                    -p tcp \
                    "$NEW_SSH_PORT" \
                    2>/dev/null \
                || semanage port \
                    -m \
                    -t ssh_port_t \
                    -p tcp \
                    "$NEW_SSH_PORT"

                ok "SELinux 已允许 SSH 端口 ${NEW_SSH_PORT}"

            fi

        else

            warn "无法获取 semanage"
            warn "SELinux 可能阻止 SSH 使用 ${NEW_SSH_PORT}"

        fi

    fi
fi


# ============================================================
# SSH 配置检查
# ============================================================

mkdir -p /run/sshd 2>/dev/null || true

info "检查 SSH 配置..."


if ! "$SSHD_BIN" -t; then

    error "SSH 配置检查失败"

    warn "正在恢复原配置..."

    cp -af \
        "$BACKUP_DIR/sshd_config" \
        "$SSH_CONFIG"

    die "SSH 配置已恢复，请检查系统 SSH 配置"

fi

ok "SSH 配置检查通过"


# ============================================================
# UFW 安装
# ============================================================

install_ufw() {

    if command -v ufw >/dev/null 2>&1; then
        return 0
    fi


    info "安装 UFW..."


    case "$PKG_MANAGER" in

        apt)
            install_packages ufw
            ;;


        dnf)

            if ! dnf install -y ufw; then

                info "默认仓库不存在 UFW，尝试 EPEL..."

                dnf install -y epel-release || true
                dnf makecache -y || true
                dnf install -y ufw

            fi
            ;;


        yum)

            if ! yum install -y ufw; then

                info "默认仓库不存在 UFW，尝试 EPEL..."

                yum install -y epel-release || true
                yum makecache -y || true
                yum install -y ufw

            fi
            ;;


        zypper)
            zypper --non-interactive install ufw
            ;;


        pacman)
            pacman -Sy --noconfirm --needed ufw
            ;;

    esac


    if ! command -v ufw >/dev/null 2>&1; then
        die "UFW 安装失败"
    fi
}


# ============================================================
# UFW 配置
#
# 只 ADD，不 reset，不修改 default policy，不删除旧规则。
# ============================================================

if [[ "$ENABLE_UFW" == true ]]; then

    install_ufw

    info "配置 UFW..."


    # SSH 必定放行
    if [[ "$CHANGE_SSH_PORT" == true ]]; then

        ufw allow "${NEW_SSH_PORT}/tcp"

    else

        ufw allow "${CURRENT_SSH_PORT}/tcp"

    fi


    # Web 端口可选
    if [[ "$OPEN_WEB_PORTS" == true ]]; then

        ufw allow 80/tcp
        ufw allow 443/tcp

    fi


    # 不修改默认策略，只启用 UFW
    ufw --force enable

    ok "UFW 已启用"

fi


# ============================================================
# 检测 SSH 服务管理方式
# ============================================================

restart_ssh() {

    # --------------------------------------------------------
    # systemd socket activation
    # Ubuntu / Debian 等部分版本可能使用
    # --------------------------------------------------------

    if command -v systemctl >/dev/null 2>&1; then


        if systemctl is-active --quiet ssh.socket 2>/dev/null; then

            info "SSH 管理方式: ssh.socket"

            systemctl daemon-reload
            systemctl restart ssh.socket

            return 0

        fi


        if systemctl is-active --quiet sshd.socket 2>/dev/null; then

            info "SSH 管理方式: sshd.socket"

            systemctl daemon-reload
            systemctl restart sshd.socket

            return 0

        fi


        # ----------------------------------------------------
        # 常规 ssh.service
        # Debian / Ubuntu
        # ----------------------------------------------------

        if systemctl is-active --quiet ssh.service 2>/dev/null \
            || systemctl list-unit-files ssh.service \
                2>/dev/null \
                | grep -q '^ssh\.service'; then

            info "SSH 管理方式: ssh.service"

            systemctl restart ssh.service

            return 0

        fi


        # ----------------------------------------------------
        # sshd.service
        # RHEL / Rocky / Alma / Fedora / Arch 等
        # ----------------------------------------------------

        if systemctl is-active --quiet sshd.service 2>/dev/null \
            || systemctl list-unit-files sshd.service \
                2>/dev/null \
                | grep -q '^sshd\.service'; then

            info "SSH 管理方式: sshd.service"

            systemctl restart sshd.service

            return 0

        fi

    fi


    # --------------------------------------------------------
    # SysV init fallback
    # --------------------------------------------------------

    if command -v service >/dev/null 2>&1; then

        if service ssh restart 2>/dev/null; then
            return 0
        fi

        if service sshd restart 2>/dev/null; then
            return 0
        fi

    fi


    return 1
}


# ============================================================
# SSH 重启
# ============================================================

info "重新加载 SSH 服务..."


if ! restart_ssh; then

    error "SSH 服务重新加载失败"

    warn "正在恢复 SSH 配置..."

    cp -af \
        "$BACKUP_DIR/sshd_config" \
        "$SSH_CONFIG"

    restart_ssh || true

    die "已尝试恢复原 SSH 配置"

fi

ok "SSH 服务已重新加载"


# ============================================================
# 新端口验证
# ============================================================

if [[ "$CHANGE_SSH_PORT" == true ]]; then

    sleep 2

    info "检查 SSH ${NEW_SSH_PORT} 端口..."


    if command -v ss >/dev/null 2>&1; then

        if ss -lntH 2>/dev/null \
            | awk '{print $4}' \
            | grep -Eq "[:.]${NEW_SSH_PORT}$"; then

            ok "SSH 已监听 ${NEW_SSH_PORT}/tcp"

        else

            error "没有检测到 SSH 监听 ${NEW_SSH_PORT}/tcp"

            echo
            echo "当前监听状态："
            echo

            ss -lntp 2>/dev/null \
                | grep -E 'ssh|sshd|systemd' \
                || true

            echo
            warn "没有删除任何旧 SSH 或 UFW 规则"

            die "新 SSH 端口验证失败"

        fi

    else

        warn "系统没有 ss 命令，无法自动确认 SSH 监听端口"

    fi

fi


# ============================================================
# 检查 firewalld
#
# 仅提示，不修改。
# ============================================================

if command -v systemctl >/dev/null 2>&1; then

    if systemctl is-active --quiet firewalld 2>/dev/null; then

        echo
        warn "检测到 firewalld 正在运行"
        warn "脚本不会关闭或修改 firewalld"
        warn "请确认 firewalld / 云厂商安全组也允许所需端口"

    fi

fi


# ============================================================
# 最终结果
# ============================================================

echo
echo "============================================================"
echo -e " ${GREEN}${BOLD}VPS 初始化完成${NC}"
echo "============================================================"
echo

echo "系统："
echo "  ${OS_NAME}"
echo

echo "Root SSH 登录："

if [[ "$ALLOW_ROOT" == true ]]; then
    echo "  允许"
else
    echo "  禁止"
fi

echo

echo "SSH："

if [[ "$CHANGE_SSH_PORT" == true ]]; then
    echo "  ${CURRENT_SSH_PORT} -> ${NEW_SSH_PORT}"
else
    echo "  ${CURRENT_SSH_PORT}"
fi

echo


if [[ "$ENABLE_UFW" == true ]]; then

    echo "UFW："

    ufw status verbose || true

else

    echo "UFW："
    echo "  未修改"

fi

echo

echo "SSH 配置备份："
echo "  ${BACKUP_DIR}"

echo


if [[ "$CHANGE_SSH_PORT" == true ]]; then

    echo "新的 SSH 登录方式："
    echo
    echo "  ssh -p ${NEW_SSH_PORT} root@服务器IP"
    echo

    warn "暂时不要关闭当前 SSH 会话"
    warn "请先打开一个新的终端测试新 SSH 端口"

fi

echo
echo "============================================================"
