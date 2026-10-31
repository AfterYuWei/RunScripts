#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# RunScripts
#
# 功能：
#   - 数字菜单，选择要执行的脚本
#
# 脚本列表：
#   1) 初始化脚本（root 仅密钥登录 + UFW）
#
# 使用：
#   bash <(curl -fsSL <raw 地址>/main.sh)
#   bash main.sh
# ============================================================


# ============================================================
# 基础配置
# ============================================================

TITLE="RunScripts"

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

    if [[ -r /dev/tty ]] && { true </dev/tty; } 2>/dev/null; then

        read -r -p "$prompt" value </dev/tty

    else

        if [[ ! -t 0 ]]; then
            die "当前环境没有可用的终端，请在终端中直接运行"
        fi

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
# 公钥格式校验
# ============================================================

validate_pubkey() {
    local key="$1"
    local tmp=""

    if [[ ! "$key" =~ ^(ssh-|ecdsa-|sk-) ]]; then
        return 1
    fi

    if command -v ssh-keygen >/dev/null 2>&1; then

        tmp="$(mktemp)"
        printf '%s\n' "$key" > "$tmp"

        if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"
            return 1
        fi

        rm -f "$tmp"

    fi

    return 0
}


# ============================================================
# 菜单
#
# 新增脚本：把函数定义好，再往 MENU_ITEMS 里加一行
# "菜单名|函数名" 即可。
# ============================================================

MENU_ITEMS=(
    "初始化脚本|init_script"
)


show_menu() {

    local index=1
    local item

    echo
    echo "============================================================"
    echo -e " ${BOLD}${TITLE}${NC}"
    echo "============================================================"
    echo

    for item in "${MENU_ITEMS[@]}"; do
        printf "  %d) %s\n" "$index" "${item%%|*}"
        index=$((index + 1))
    done

    printf "  0) 退出\n"
    echo
}


run_menu() {

    local choice=""
    local total="${#MENU_ITEMS[@]}"
    local fn=""

    while true; do

        show_menu

        read_input choice "请输入序号 [0-${total}]: "


        case "$choice" in

            0)
                info "已退出"
                return 0
                ;;

            ''|*[!0-9]*)
                warn "请输入数字"
                continue
                ;;

        esac


        if (( choice < 1 || choice > total )); then
            warn "无效序号: ${choice}"
            continue
        fi


        fn="${MENU_ITEMS[choice-1]#*|}"

        if ! declare -F "$fn" >/dev/null 2>&1; then
            error "未找到函数: ${fn}"
            return 1
        fi


        "$fn"
        return 0

    done
}


# ============================================================
# 初始化脚本
#
# 功能：
#   - 可选允许 root 登录（默认允许，且仅接受密钥）
#   - 可选关闭密码登录（默认关闭）
#   - 可追加 root 登录公钥（默认内置公钥，可换成自己的或跳过）
#   - 可选修改 SSH 端口
#   - 可选安装并启用 UFW
#   - UFW 自动放行 SSH 端口
#   - 可选放行 80 / 443
#
# 交互：
#   - 先一次性收集全部配置，确认后连续执行，中途不再询问
#   - 提示中标出的即默认值，直接回车即采用
#
# 原则：
#   - 不清空 UFW
#   - 不修改 UFW 默认策略
#   - 不删除用户已有规则
#   - 不删除旧 SSH 规则
#   - 不关闭其他防火墙
#   - 不改变发行版原有 SSH 服务模式
#   - authorized_keys 只追加，不覆盖已有公钥
#   - 任一步骤失败自动回滚
# ============================================================

init_script() {

    # --------------------------------------------------------
    # 基础配置
    # --------------------------------------------------------

    DEFAULT_SSH_PORT="32222"
    SSH_CONFIG="/etc/ssh/sshd_config"

    # 内置公钥（默认追加的公钥，可交互替换）
    SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM+bYLFeFefrvoSwzNbLzFkVAheKneSJ4o9tv7kXPaJC"
    AUTHORIZED_KEYS="/root/.ssh/authorized_keys"


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
    #
    # 所有信息在这里一次问完，确认后连续执行，中途不再询问。
    # 提示中的取值即默认值，直接回车即采用。
    # ============================================================

    echo

    # ---------------- root 登录 ----------------

    ALLOW_ROOT=false

    if ask_yes_no "是否允许 root SSH 登录？" "Y"; then
        ALLOW_ROOT=true
    fi


    # ---------------- 密码登录 ----------------

    DISABLE_PASSWORD=false

    if ask_yes_no "是否关闭密码登录（仅允许密钥登录）？" "Y"; then
        DISABLE_PASSWORD=true
    fi


    # ---------------- 登录公钥 ----------------

    PUBKEY_TO_ADD=""

    if [[ "$ALLOW_ROOT" == true ]]; then

        echo

        info "root 现有公钥（${AUTHORIZED_KEYS}）："

        if [[ -s "$AUTHORIZED_KEYS" ]]; then

            while read -r key_type key_body _; do

                if [[ -z "$key_type" ]]; then
                    continue
                fi

                echo "  ${key_type} ${key_body:0:16}..."

            done < "$AUTHORIZED_KEYS"

        else

            echo "  （无）"

        fi

        echo

        while true; do

            KEY_INPUT=""

            read_input \
                KEY_INPUT \
                "追加 root 登录公钥 [回车=内置公钥, skip=不修改]: "

            if [[ "$KEY_INPUT" == "skip" || "$KEY_INPUT" == "SKIP" ]]; then

                PUBKEY_TO_ADD=""
                break

            fi


            if [[ -z "$KEY_INPUT" ]]; then

                PUBKEY_TO_ADD="$SSH_PUBKEY"
                break

            fi


            if ! validate_pubkey "$KEY_INPUT"; then
                warn "公钥格式不正确，请重新输入（或以 skip 跳过）"
                continue
            fi


            PUBKEY_TO_ADD="$KEY_INPUT"
            break

        done

    fi


    # ---------------- 防锁死检查 ----------------

    if [[ "$DISABLE_PASSWORD" == true && "$ALLOW_ROOT" == true ]]; then

        AVAILABLE_KEY=false

        if [[ -n "$PUBKEY_TO_ADD" ]]; then

            AVAILABLE_KEY=true

        elif [[ -s "$AUTHORIZED_KEYS" ]] \
            && grep -qE '^(ssh-|ecdsa-|sk-)' "$AUTHORIZED_KEYS"; then

            AVAILABLE_KEY=true

        fi


        if [[ "$AVAILABLE_KEY" != true ]]; then

            warn "即将关闭密码登录，但 root 下没有任何可用公钥"
            warn "继续执行会失去 root 登录能力"

            if ! ask_yes_no "仍然继续？" "N"; then
                warn "已取消"
                exit 0
            fi

        fi

    fi


    # ---------------- SSH 端口 ----------------

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
        echo "允许（仅密钥）"
    else
        echo "禁止"
    fi


    echo -n "密码登录:           "

    if [[ "$DISABLE_PASSWORD" == true ]]; then
        echo "关闭"
    else
        echo "保持现状"
    fi


    echo -n "追加登录公钥:       "

    if [[ -n "$PUBKEY_TO_ADD" ]]; then
        echo "${PUBKEY_TO_ADD:0:11} ${PUBKEY_TO_ADD: -20}"
    else
        echo "不修改"
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


    if [[ -f "$AUTHORIZED_KEYS" ]]; then

        cp -a "$AUTHORIZED_KEYS" "$BACKUP_DIR/authorized_keys" || true

    else

        warn "未发现 ${AUTHORIZED_KEYS}，回滚时将删除本次新增公钥"
        : > "$BACKUP_DIR/no-authorized-keys"

    fi

    ok "SSH 配置已备份到 ${BACKUP_DIR}"


    # ============================================================
    # 公钥安装
    #
    # 关闭密码登录前，必须先确认公钥已就位，否则会把自己锁在门外。
    # ============================================================

    install_ssh_key() {

        local key_dir

        if [[ -z "$PUBKEY_TO_ADD" ]]; then
            return 0
        fi

        key_dir="$(dirname "$AUTHORIZED_KEYS")"

        mkdir -p "$key_dir"
        chmod 700 "$key_dir"

        touch "$AUTHORIZED_KEYS"
        chmod 600 "$AUTHORIZED_KEYS"


        if grep -qxF "$PUBKEY_TO_ADD" "$AUTHORIZED_KEYS" 2>/dev/null; then

            ok "公钥已存在，无需重复写入"

        else

            printf '%s\n' "$PUBKEY_TO_ADD" >> "$AUTHORIZED_KEYS"
            ok "公钥已写入 ${AUTHORIZED_KEYS}"

        fi


        if ! grep -qxF "$PUBKEY_TO_ADD" "$AUTHORIZED_KEYS" 2>/dev/null; then
            die "公钥写入失败，已中止（SSH 配置未修改）"
        fi


        # SELinux 环境下修正文件上下文
        if command -v restorecon >/dev/null 2>&1; then
            restorecon -R "$key_dir" 2>/dev/null || true
        fi
    }


    if [[ -n "$PUBKEY_TO_ADD" ]]; then

        install_ssh_key

    else

        info "未指定新公钥，跳过 authorized_keys 写入"

    fi


    # ============================================================
    # 回滚
    #
    # 恢复 sshd_config 与 authorized_keys 到执行前状态。
    # ============================================================

    restore_backup() {

        if [[ -f "$BACKUP_DIR/sshd_config" ]]; then

            cp -af "$BACKUP_DIR/sshd_config" "$SSH_CONFIG"
            warn "SSH 配置已恢复"

        fi


        if [[ -f "$BACKUP_DIR/no-authorized-keys" ]]; then

            # 原文件不存在，删除本次新增的公钥
            if [[ -n "$PUBKEY_TO_ADD" && -f "$AUTHORIZED_KEYS" ]]; then

                local tmp
                tmp="$(mktemp)"

                grep -vxF "$PUBKEY_TO_ADD" "$AUTHORIZED_KEYS" > "$tmp" || true
                cat "$tmp" > "$AUTHORIZED_KEYS"
                rm -f "$tmp"

                warn "已移除本次新增公钥"

            fi

        elif [[ -f "$BACKUP_DIR/authorized_keys" ]]; then

            cp -af "$BACKUP_DIR/authorized_keys" "$AUTHORIZED_KEYS"
            warn "authorized_keys 已恢复"

        fi
    }


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


    # ChallengeResponseAuthentication 在 8.7 起改名为 KbdInteractiveAuthentication
    SSHD_EFFECTIVE_CONFIG="$("$SSHD_BIN" -T 2>/dev/null || true)"

    if [[ "$SSHD_EFFECTIVE_CONFIG" == *kbdinteractiveauthentication* ]]; then
        KBD_AUTH_OPTION="KbdInteractiveAuthentication"
    else
        KBD_AUTH_OPTION="ChallengeResponseAuthentication"
    fi


    {
        echo "$MANAGED_BEGIN"

        if [[ "$ALLOW_ROOT" == true ]]; then
            # root 允许登录，但只接受密钥
            echo "PermitRootLogin prohibit-password"
        else
            echo "PermitRootLogin no"
        fi

        if [[ "$DISABLE_PASSWORD" == true ]]; then
            echo "PubkeyAuthentication yes"
            echo "PasswordAuthentication no"
            echo "PermitEmptyPasswords no"
            echo "${KBD_AUTH_OPTION} no"
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

        restore_backup

        die "SSH 配置已恢复，请检查系统 SSH 配置"

    fi

    ok "SSH 配置检查通过"


    # ============================================================
    # 生效策略检查
    #
    # 防止被 drop-in / 发行版默认值覆盖后仍继续执行。
    # ============================================================

    EFFECTIVE_CONFIG="$("$SSHD_BIN" -T 2>/dev/null || true)"

    if [[ "$DISABLE_PASSWORD" == true ]] \
        && [[ "$EFFECTIVE_CONFIG" != *"passwordauthentication no"* ]]; then

        error "生效配置中密码登录未被关闭"

        restore_backup

        die "已恢复原 SSH 配置"

    fi


    if [[ "$ALLOW_ROOT" == true ]]; then

        case "$EFFECTIVE_CONFIG" in

            *"permitrootlogin prohibit-password"*) ;;
            *"permitrootlogin without-password"*) ;;

            *)
                error "生效配置中 root 密钥登录未开启"

                restore_backup

                die "已恢复原 SSH 配置"
                ;;

        esac

    elif [[ "$EFFECTIVE_CONFIG" != *"permitrootlogin no"* ]]; then

        error "生效配置中 root 登录未被禁止"

        restore_backup

        die "已恢复原 SSH 配置"

    fi

    ok "生效策略确认"


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

        restore_backup

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

    echo "登录方式："

    if [[ "$ALLOW_ROOT" == true ]]; then
        echo "  root 登录：允许（仅密钥）"
    else
        echo "  root 登录：禁止"
    fi

    if [[ "$DISABLE_PASSWORD" == true ]]; then
        echo "  密码登录：关闭"
    else
        echo "  密码登录：保持现状"
    fi

    if [[ -n "$PUBKEY_TO_ADD" ]]; then
        echo "  新增公钥：${PUBKEY_TO_ADD:0:11} ${PUBKEY_TO_ADD: -20}"
    else
        echo "  新增公钥：无"
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


    LOGIN_USER="root"

    if [[ "$ALLOW_ROOT" == true ]]; then

        echo "SSH 登录方式："
        echo

        if [[ "$CHANGE_SSH_PORT" == true ]]; then
            echo "  ssh -i ~/.ssh/id_ed25519 -p ${NEW_SSH_PORT} ${LOGIN_USER}@服务器IP"
        else
            echo "  ssh -i ~/.ssh/id_ed25519 ${LOGIN_USER}@服务器IP"
        fi

        echo

    fi

    if [[ "$DISABLE_PASSWORD" == true ]]; then
        warn "密码登录已关闭，仅能使用对应私钥登录"
        warn "请先打开一个新的终端用私钥登录成功，再关闭当前会话"
    fi

    if [[ "$CHANGE_SSH_PORT" == true ]]; then
        warn "端口已变更，请在新终端确认端口可登录后再关闭当前会话"
    fi

    warn "暂时不要关闭当前 SSH 会话"

    echo
    echo "============================================================"
}


# ============================================================
# 入口
# ============================================================

main() {
    run_menu
}

main "$@"
