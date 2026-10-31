#!/usr/bin/env bash
# Debian reinstall frontend. Engine: https://github.com/bin456789/reinstall
set +x
set -Eeuo pipefail
umask 077
readonly ENGINE_COMMIT=54fae2067557b3c0ca49e7c9ce03bca63c793f8c
readonly ENGINE_SHA256=3ca358bf065ebd3ecb2f727e152a4b4fb9b154398abc1b9a5fe0b599f1027d7a
# Update the pinned engine and verify new releases before extending this list.
readonly SUPPORTED_VERSIONS='13'
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' '用法：bash install.sh [--dry-run | --cancel | --help]' \
        '--dry-run 仅检查输入，不下载、不修改系统' \
        '--cancel 取消本脚本已经准备、尚未重启的重装任务'
}
main() {
    local mode=install version port root_password password_confirm answer arch virt command_name
    local engine_dir='' engine_file
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
    if [[ $mode == cancel ]]; then
        [[ -f /root/.debian-reinstall/engine.sh && ! -L /root/.debian-reinstall/engine.sh ]] || die '没有找到本脚本保留的重装引擎'
        bash /root/.debian-reinstall/engine.sh reset <&9
        return
    fi
    arch=$(uname -m)
    case "$arch" in x86_64|aarch64) ;; *) die "暂不支持架构：$arch" ;; esac
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt --container 2>/dev/null || true)
        [[ -z $virt || $virt == none ]] || die "容器不能重装内核：$virt"
    fi
    [[ ! -e /.dockerenv && ! -e /run/.containerenv && ! -d /proc/vz ]] || die '不支持 Docker/Podman/OpenVZ 容器'
    printf '\nDebian 一键重装（将清空系统整块硬盘，含其他分区）\n'
    printf '当前支持 Debian %s；架构 %s。请先备份，并准备商家 VNC/救援控制台。\n' "$SUPPORTED_VERSIONS" "$arch"
    printf '请在云安全组/外部防火墙放行你选择的 SSH TCP 端口。\n'
    while true; do
        read -r -p 'Debian 主版本 [13]：' version <&9 || return 1
        version=${version:-13}
        [[ " $SUPPORTED_VERSIONS " == *" $version "* && $version =~ ^[0-9]+$ ]] && break
        printf '该固定版本引擎尚未支持 Debian %s；目前仅支持 %s。\n' "$version" "$SUPPORTED_VERSIONS"
    done
    while true; do
        read -r -p 'SSH 端口 [22]：' port <&9 || return 1
        port=${port:-22}
        if [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); then
            port=$((10#$port)); break
        fi
        printf '端口必须为 1–65535 的整数。\n'
    done
    while true; do
        read -r -s -p 'root 密码（至少 12 字符）：' root_password <&9 || return 1
        printf '\n'
        [[ ${#root_password} -ge 12 && $root_password != *$'\r'* ]] || { printf '密码至少 12 字符，不能含回车。\n'; continue; }
        read -r -s -p '再次输入 root 密码：' password_confirm <&9 || return 1
        printf '\n'
        [[ $root_password == "$password_confirm" ]] && break
        printf '两次密码不同，请重新输入。\n'
    done
    unset password_confirm
    printf '\n目标：Debian %s；SSH TCP 端口：%s；登录用户：root\n' "$version" "$port"
    if [[ $mode == dry-run ]]; then
        unset root_password
        printf '检查完成：未下载引擎、未修改系统、未安排重启。\n'
        return
    fi
    read -r -p '确认已备份且允许清空系统整块硬盘？输入 ERASE：' answer <&9 || return 1
    [[ $answer == ERASE ]] || { unset root_password; printf '已取消。\n'; return; }
    for command_name in curl sha256sum sed mktemp; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少依赖：$command_name，请用系统包管理器安装"
    done
    engine_dir=$(mktemp -d /root/.debian-reinstall-download.XXXXXXXX)
    # mktemp produces a path beneath /root with only safe template characters.
    # shellcheck disable=SC2064
    trap "rm -rf -- '$engine_dir'" EXIT
    engine_file=$engine_dir/engine.sh
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 180 --retry 3 \
        "https://raw.githubusercontent.com/bin456789/reinstall/$ENGINE_COMMIT/reinstall.sh" -o "$engine_file"
    printf '%s  %s\n' "$ENGINE_SHA256" "$engine_file" | sha256sum --check --status || die '引擎校验失败'
    # Upstream --commit is currently inactive. Pin both resource base URLs explicitly.
    sed -i \
        -e "s|^confhome=https://raw.githubusercontent.com/bin456789/reinstall/main$|confhome=https://raw.githubusercontent.com/bin456789/reinstall/$ENGINE_COMMIT|" \
        -e "s|^confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/main$|confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/$ENGINE_COMMIT|" "$engine_file"
    [[ ! -L /root/.debian-reinstall ]] || die '引擎目录不能是符号链接'
    mkdir -p /root/.debian-reinstall
    chmod 700 /root/.debian-reinstall
    [[ ! -L /root/.debian-reinstall/engine.sh ]] || die '引擎文件不能是符号链接'
    cp -- "$engine_file" /root/.debian-reinstall/engine.sh
    chmod 600 /root/.debian-reinstall/engine.sh
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
    printf '\n重装已准备。确认无误后执行 reboot 开始安装。\n'
    printf '新系统登录：ssh -p %s root@服务器IP\n' "$port"
    printf '重启前可运行：bash install.sh --cancel\n'
}
main "$@"
