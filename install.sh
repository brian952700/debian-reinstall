#!/usr/bin/env bash
# Debian reinstall frontend. Engine: https://github.com/bin456789/reinstall
set +x
set -Eeuo pipefail
umask 077
readonly ENGINE_COMMIT=54fae2067557b3c0ca49e7c9ce03bca63c793f8c
readonly ENGINE_SHA256=3ca358bf065ebd3ecb2f727e152a4b4fb9b154398abc1b9a5fe0b599f1027d7a
# Update the pinned engine and verify new releases before extending this list.
readonly SUPPORTED_VERSIONS='13'
C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM=''
init_ui() {
    if [[ -t 1 && -t 2 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
        C_RESET=$'\033[0m' C_CYAN=$'\033[1;36m' C_GREEN=$'\033[1;32m'
        C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m' C_DIM=$'\033[2m'
    fi
}
step() { printf '\n%s  步骤 %s/4 · %s%s\n  ────────────────────────\n' "$C_CYAN" "$1" "$2" "$C_RESET"; }
note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
success() { printf '\n  %s✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warning() { printf '\n  %s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
input_error() { printf '  %s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
prompt_text() {
    printf '\n  %s%s%s' "$C_CYAN" "$1" "$C_RESET"
    [[ -z ${2:-} ]] || printf ' %s%s%s' "$C_DIM" "$2" "$C_RESET"
    printf '：'
}
prompt() { prompt_text "$@" >&2; }
die() { printf '\n  %s✗ 错误：%s%s\n\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
usage() {
    printf '%s\n' '用法：bash install.sh [--dry-run | --cancel | --help]' \
        '--dry-run 仅检查输入，不下载、不修改系统' \
        '--cancel 取消本脚本已经准备、尚未重启的重装任务'
}
main() {
    local mode=install version port root_password password_confirm answer arch virt command_name
    local engine_dir='' engine_file
    init_ui
    case "${1:-}" in
        '') ;;
        --help|-h) usage; return ;;
        --dry-run) mode=dry-run ;;
        --cancel) mode=cancel ;;
        *) usage; return 1 ;;
    esac
    (( $# <= 1 )) || die '不接受额外参数'
    [[ $(uname -s) == Linux ]] || die '请在目标 Linux 服务器上运行'
    (( EUID == 0 )) || die '请使用 root 或 sudo bash install.sh'
    # A dedicated descriptor also permits: curl ... | bash
    exec 9<>/dev/tty || die '需要交互终端，请下载后在 SSH 终端执行'
    printf '\n%s  Debian 一键重装%s\n' "$C_CYAN" "$C_RESET"
    note '设置 SSH 端口与 root 密码 · 按 Ctrl+C 退出'
    if [[ $mode == cancel ]]; then
        warning '正在取消尚未重启的重装安排…'
        [[ -f /root/.debian-reinstall/engine.sh && ! -L /root/.debian-reinstall/engine.sh ]] || die '没有找到本脚本保留的重装引擎'
        bash /root/.debian-reinstall/engine.sh reset <&9
        success '取消命令已完成，请检查上方引擎结果。'
        return
    fi
    step 1 '环境检查'
    arch=$(uname -m)
    case "$arch" in x86_64|aarch64) ;; *) die "暂不支持架构：$arch" ;; esac
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt --container 2>/dev/null || true)
        [[ -z $virt || $virt == none ]] || die "容器不能重装内核：$virt"
    fi
    [[ ! -e /.dockerenv && ! -e /run/.containerenv && ! -d /proc/vz ]] || die '不支持 Docker/Podman/OpenVZ 容器'
    success "环境检查通过 · $arch"
    note "可安装版本：Debian $SUPPORTED_VERSIONS"
    warning '重装将清空系统整块硬盘，包括其他分区。'
    note '请先备份，并准备商家 VNC / 救援控制台。'
    note '请在云安全组 / 外部防火墙放行所选 SSH TCP 端口。'
    [[ $mode != dry-run ]] || note '当前为试运行：仅体验设置，不下载、不修改系统。'
    step 2 '安装设置'
    note '直接回车使用默认值。密码输入时不显示字符。'
    while true; do
        prompt 'Debian 主版本' '[默认：13]'
        read -r version <&9 || return 1
        version=${version:-13}
        [[ " $SUPPORTED_VERSIONS " == *" $version "* && $version =~ ^[0-9]+$ ]] && break
        input_error "该版本尚未支持，目前可选：$SUPPORTED_VERSIONS。"
    done
    while true; do
        prompt 'SSH 端口' '[默认：22]'
        read -r port <&9 || return 1
        port=${port:-22}
        if [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); then
            port=$((10#$port)); break
        fi
        input_error '端口必须为 1–65535 的整数，请重新输入。'
    done
    while true; do
        read -r -s -p "$(prompt_text 'root 密码' '[至少 12 字符，隐藏输入]')" root_password <&9 || return 1
        printf '\n'
        [[ ${#root_password} -ge 12 && $root_password != *$'\r'* ]] || { input_error '密码至少 12 字符，不能含回车。'; continue; }
        read -r -s -p "$(prompt_text '再次输入 root 密码')" password_confirm <&9 || return 1
        printf '\n'
        [[ $root_password == "$password_confirm" ]] && break
        input_error '两次密码不同，请重新输入密码；版本和端口已保留。'
    done
    unset password_confirm
    success '安装设置已完成'
    step 3 '确认重装'
    printf '\n  目标系统    Debian %s\n  系统架构    %s\n  SSH 端口    %s\n  登录用户    root\n  登录密码    已设置（隐藏）\n' "$version" "$arch" "$port"
    if [[ $mode == dry-run ]]; then
        unset root_password
        step 4 '试运行完成'
        success '检查完成：未下载引擎、未修改系统、未安排重启。'
        printf '\n'
        return
    fi
    warning '将清空系统整块硬盘，包括其他分区，数据无法通过本脚本恢复。'
    note '确认已备份，并已放行上方 SSH 端口后继续。'
    prompt '确认继续，请输入 ERASE'
    read -r answer <&9 || return 1
    [[ $answer == ERASE ]] || { unset root_password; warning '已取消，未准备重装。'; printf '\n'; return; }
    step 4 '准备重装'
    for command_name in curl sha256sum sed mktemp; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少依赖：$command_name，请用系统包管理器安装"
    done
    engine_dir=$(mktemp -d /root/.debian-reinstall-download.XXXXXXXX)
    # mktemp produces a path beneath /root with only safe template characters.
    # shellcheck disable=SC2064
    trap "rm -rf -- '$engine_dir'" EXIT
    engine_file=$engine_dir/engine.sh
    note '正在下载重装引擎…'
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 180 --retry 3 \
        "https://raw.githubusercontent.com/bin456789/reinstall/$ENGINE_COMMIT/reinstall.sh" -o "$engine_file" || die '下载失败，请检查网络后重试；不要重启'
    success '引擎下载完成'
    note '正在校验 SHA256…'
    printf '%s  %s\n' "$ENGINE_SHA256" "$engine_file" | sha256sum --check --status || die '引擎校验失败'
    success '引擎校验通过'
    # Upstream --commit is currently inactive. Pin both resource base URLs explicitly.
    sed -i \
        -e "s|^confhome=https://raw.githubusercontent.com/bin456789/reinstall/main$|confhome=https://raw.githubusercontent.com/bin456789/reinstall/$ENGINE_COMMIT|" \
        -e "s|^confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/main$|confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/$ENGINE_COMMIT|" "$engine_file"
    # Upstream prints the chosen password in its final summary. Hide that output.
    # shellcheck disable=SC2016
    sed -i 's/echo "Password: \$password/echo "Password: [hidden]/g' "$engine_file"
    [[ ! -L /root/.debian-reinstall ]] || die '引擎目录不能是符号链接'
    mkdir -p /root/.debian-reinstall
    chmod 700 /root/.debian-reinstall
    [[ ! -L /root/.debian-reinstall/engine.sh ]] || die '引擎文件不能是符号链接'
    cp -- "$engine_file" /root/.debian-reinstall/engine.sh
    chmod 600 /root/.debian-reinstall/engine.sh
    note '正在调用安装引擎，以下为引擎的详细输出。'
    note '请核对网络和磁盘信息；此过程可能需要几分钟。'
    printf '\n'
    # The pinned engine reads an existing shell variable named password.
    # Feed it through a descriptor, then source in a separate Bash process.
    # The secret never enters argv, exported environment, or our files.
    # shellcheck disable=SC2016
    if bash -c 'IFS= read -r password <&3; exec 3<&-; source "$0" "$@"' \
        /root/.debian-reinstall/engine.sh debian "$version" --username root --ssh-port "$port" \
        3<<< "$root_password" <&9; then
        unset root_password
    else
        unset root_password
        die '准备失败；不要重启。检查引擎输出，可运行 bash install.sh --cancel 取消引导项'
    fi
    success '重装已准备完成'
    note '确认上方引擎结果无误后，手动重启开始安装。'
    printf '\n  开始安装\n    %sreboot%s\n' "$C_CYAN" "$C_RESET"
    printf '\n  新系统 SSH 登录（替换服务器IP）\n    %sssh -p %s root@服务器IP%s\n' "$C_CYAN" "$port" "$C_RESET"
    printf '\n  重启前取消重装\n    %sbash install.sh --cancel%s\n\n' "$C_CYAN" "$C_RESET"
}
main "$@"
