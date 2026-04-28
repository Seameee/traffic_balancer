#!/usr/bin/env bash
#
# traffic_balance.sh
# 跨平台服务器流量监控与自动平衡脚本
# 版本: 1.0.0
#
# 功能: 基于 vnstat 监控月度 RX/TX 流量比例，当比例 <= 2 时自动下载指定文件平衡流量
#       支持 Telegram 远程查询流量状态，可安装为 systemd/OpenRC/SysV 持久化服务
#
# 兼容: Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine, Arch, openSUSE
#       KVM/LXC/VMware/物理机, amd64/arm64/armv7l/i386
#
# 用法: ./traffic_balance.sh [选项]
#       ./traffic_balance.sh --install-service -d 15
#       ./traffic_balance.sh --self-test
#

set -uo pipefail

# ============================================
# 全局常量与默认配置
# ============================================

# 脚本版本
readonly SCRIPT_VERSION="1.0.0"

# 默认配置值 (会被配置文件和命令行参数覆盖)
RESET_DAY=1
INTERFACE=""
LIMIT_RATE="1M"
CHECK_INTERVAL=60
TG_POLL_INTERVAL=5
CONNECT_TIMEOUT=30
MAX_DOWNLOAD_TIME=7200

# Telegram 配置 (空值表示禁用)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ALLOWED_USER_ID=""

# 日志文件轮转阈值 (10 MiB)
readonly MAX_LOG_SIZE=$((10 * 1024 * 1024))

# ============================================
# 下载 URL 列表 (硬编码，不可修改顺序)
# ============================================
DOWNLOAD_URLS=(
    "https://mirrors.aliyun.com/deepin-cd/20.9/deepin-desktop-community-20.9-amd64.iso"
    "https://dldir1.qq.com/weixin/Windows/WeChatSetup.exe"
    "http://speedtest.tele2.net/10MB.zip"
    "http://speedtest.tele2.net/100MB.zip"
    "http://speedtest.tokyo2.linode.com/100MB-tokyo2.bin"
    "http://speedtest.singapore.linode.com/100MB-singapore.bin"
    "http://speedtest.fremont.linode.com/100MB-fremont.bin"
    "http://speedtest.newark.linode.com/100MB-newark.bin"
    "http://speedtest.london.linode.com/100MB-london.bin"
    "http://speedtest.frankfurt.linode.com/100MB-frankfurt.bin"
    "http://speedtest.dallas.linode.com/100MB-dallas.bin"
    "http://speedtest.atlanta.linode.com/100MB-atlanta.bin"
    "http://lon.download.datapacket.com/100mb.bin"
    "http://fra.download.datapacket.com/100mb.bin"
    "http://tyo.download.datapacket.com/100mb.bin"
    "http://sin.download.datapacket.com/100mb.bin"
    "http://mad.download.datapacket.com/100mb.bin"
    "http://par.download.datapacket.com/100mb.bin"
    "http://sto.download.datapacket.com/100mb.bin"
    "https://nj-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://il-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://ga-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://fl-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://tx-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://sjo-ca-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://lax-ca-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://wa-us-ping.vultr.com/vultr.com.100MB.bin"
    "https://tor-ca-ping.vultr.com/vultr.com.100MB.bin"
    "https://fra-de-ping.vultr.com/vultr.com.100MB.bin"
    "https://par-fr-ping.vultr.com/vultr.com.100MB.bin"
    "https://ams-nl-ping.vultr.com/vultr.com.100MB.bin"
    "https://lon-gb-ping.vultr.com/vultr.com.100MB.bin"
    "https://sgp-ping.vultr.com/vultr.com.100MB.bin"
    "https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin"
    "https://syd-au-ping.vultr.com/vultr.com.100MB.bin"
    "https://mex-mx-ping.vultr.com/vultr.com.100MB.bin"
    "https://mel-au-ping.vultr.com/vultr.com.100MB.bin"
    "https://sto-se-ping.vultr.com/vultr.com.100MB.bin"
    "http://ping.online.net/100Mb.dat"
    "http://speedtest.sydney.linode.com/100MB-sydney.bin"
    "https://raw.githubusercontent.com/torvalds/linux/master/COPYING"
    "https://ossweb-img.qq.com/images/lol/web201310/skin/big10001.jpg"
    "https://lf5-j1gamecdn-cn.dailygn.com/obj/lf-game-lf/gdl_app_2682/1233880772355.mp4"
    "http://proof.ovh.net/files/100Mb.dat"
    "http://rbx.proof.ovh.net/files/100Mb.dat"
    "http://sbg.proof.ovh.net/files/100Mb.dat"
    "http://gra.proof.ovh.net/files/100Mb.dat"
    "https://ysh2.gz-hezhi.com:8899/downloads/ysh_pc_latest.exe"
)

# ============================================
# 流量数据缓存
# ============================================
CACHED_RX=""
CACHED_TX=""

# ============================================
# Telegram 状态
# ============================================
TELEGRAM_ENABLED=false
API_BASE=""
LAST_UPDATE_ID=0

# ============================================
# 路径变量 (由 setup_paths() 设置)
# ============================================
SCRIPT_PIDFILE=""
CURL_PIDFILE=""
LOG_FILE=""

# ============================================
# 函数: setup_paths
# 说明: 根据当前用户权限设置 PID 文件、curl PID 文件和日志文件路径
# 参数: 无
# 输出: 无 (设置全局变量)
# ============================================
setup_paths() {
    if [ "$(id -u)" -eq 0 ]; then
        SCRIPT_PIDFILE="/var/run/traffic_balance.pid"
        CURL_PIDFILE="/var/run/traffic_balance_curl.pid"
        LOG_FILE="/var/log/traffic_balance.log"
    else
        SCRIPT_PIDFILE="${HOME}/.cache/traffic_balance/pid"
        CURL_PIDFILE="${HOME}/.cache/traffic_balance/curl_pid"
        LOG_FILE="${HOME}/.local/state/traffic_balance.log"
    fi
}

# ============================================
# 函数: log
# 说明: 记录日志到文件并输出到 stderr
# 参数: $1 = 级别 (INFO|WARN|ERROR), $2+ = 消息内容
# 输出: 带时间戳的日志行到 stderr 和日志文件
# ============================================
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local log_dir
    log_dir=$(dirname "${LOG_FILE}")
    mkdir -p "${log_dir}" 2>/dev/null || true

    # 日志轮转: 超过 MAX_LOG_SIZE 时备份旧日志
    if [ -f "${LOG_FILE}" ] && [ "$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)" -gt "${MAX_LOG_SIZE}" ]; then
        mv "${LOG_FILE}" "${LOG_FILE}.old"
    fi

    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${LOG_FILE}" >&2
}

# ============================================
# 函数: human_bytes
# 说明: 将字节数转换为人类可读的格式
# 参数: $1 = 字节数 (整数)
# 输出: 如 "1.23 GiB", "456.78 MiB" 等
# ============================================
human_bytes() {
    local bytes="$1"
    if [ "${bytes}" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GiB\", ${bytes}/1073741824}"
    elif [ "${bytes}" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MiB\", ${bytes}/1048576}"
    elif [ "${bytes}" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KiB\", ${bytes}/1024}"
    else
        echo "${bytes} bytes"
    fi
}

# ============================================
# 函数: get_max_day_of_month
# 说明: 获取指定年月的最大天数
# 参数: $1 = 年份, $2 = 月份 (1-12)
# 输出: 最大天数 (28-31)
# ============================================
get_max_day_of_month() {
    local year="$1"
    local month="$2"

    # 方法 1: 使用 date 命令 (GNU date 及大部分 BSD 兼容)
    date -d "${year}-${month}-01 +1 month -1 day" '+%d' 2>/dev/null || \
    # 方法 2: cal + awk (BusyBox / Alpine 兼容)
    cal "${month}" "${year}" 2>/dev/null | awk 'NF {d=$NF} END {print d}' || \
    # 方法 3: 硬编码 fallback
    case "${month}" in
        2)
            if (( year % 400 == 0 )) || (( year % 4 == 0 && year % 100 != 0 )); then
                echo 29
            else
                echo 28
            fi ;;
        4|6|9|11) echo 30 ;;
        *) echo 31 ;;
    esac
}

# ============================================
# 函数: detect_os_type
# 说明: 自动检测当前 Linux 发行版类型
# 参数: 无
# 输出: debian|rhel|alpine|arch|opensuse|unknown
# ============================================
detect_os_type() {
    local os_id=""

    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        os_id=$(. /etc/os-release && echo "${ID}")
    fi

    case "${os_id}" in
        debian|ubuntu)
            echo "debian" ;;
        fedora|rhel|centos|rocky|almalinux)
            echo "rhel" ;;
        alpine)
            echo "alpine" ;;
        arch|manjaro)
            echo "arch" ;;
        opensuse*|suse*)
            echo "opensuse" ;;
        *)
            # fallback: 检查包管理器
            if command -v apt-get >/dev/null 2>&1; then
                echo "debian"
            elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
                echo "rhel"
            elif command -v apk >/dev/null 2>&1; then
                echo "alpine"
            elif command -v pacman >/dev/null 2>&1; then
                echo "arch"
            elif command -v zypper >/dev/null 2>&1; then
                echo "opensuse"
            else
                echo "unknown"
            fi ;;
    esac
}

# ============================================
# 函数: install_dependencies
# 说明: 自动检测并安装必要依赖 (vnstat, curl, jq 等)
# 参数: 无
# 输出: 安装日志
# 返回: 0 成功, 1 失败
# ============================================
install_dependencies() {
    local os_type
    os_type=$(detect_os_type)
    local missing_pkgs=()

    # 检查必要命令
    if ! command -v curl >/dev/null 2>&1; then
        missing_pkgs+=("curl")
    fi

    if ! command -v vnstat >/dev/null 2>&1; then
        missing_pkgs+=("vnstat")
    fi

    # jq 是可选但有则优先
    if ! command -v jq >/dev/null 2>&1; then
        # 检查是否有 python3/python2 作为 fallback
        if ! command -v python3 >/dev/null 2>&1 && ! command -v python2 >/dev/null 2>&1; then
            missing_pkgs+=("jq")
        fi
    fi

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        log INFO "所有必要依赖已安装"
        return 0
    fi

    log INFO "需要安装依赖: ${missing_pkgs[*]}"

    # 非 root 无法自动安装
    if [ "$(id -u)" -ne 0 ]; then
        log ERROR "缺少依赖 ${missing_pkgs[*]}，但非 root 用户无法自动安装。请手动安装后重试。"
        return 1
    fi

    local pkg_manager=""
    local install_cmd=""

    case "${os_type}" in
        debian)
            pkg_manager="apt-get"
            install_cmd="apt-get update && apt-get install -y"
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                pkg_manager="dnf"
                install_cmd="dnf install -y"
            else
                pkg_manager="yum"
                install_cmd="yum install -y"
            fi
            ;;
        alpine)
            pkg_manager="apk"
            install_cmd="apk add"
            ;;
        arch)
            pkg_manager="pacman"
            install_cmd="pacman -Sy --noconfirm"
            ;;
        opensuse)
            pkg_manager="zypper"
            install_cmd="zypper install -y"
            ;;
        *)
            log ERROR "无法识别的发行版，无法自动安装依赖。请手动安装: ${missing_pkgs[*]}"
            return 1
            ;;
    esac

    log INFO "使用 ${pkg_manager} 安装依赖..."
    # shellcheck disable=SC2086
    if eval "${install_cmd} ${missing_pkgs[*]}"; then
        log INFO "依赖安装成功"
        return 0
    else
        log ERROR "依赖安装失败"
        return 1
    fi
}

# ============================================
# 函数: detect_interface
# 说明: 检测外网网卡名称，优先使用已配置值，否则自动检测
# 参数: 无 (使用全局 INTERFACE 变量)
# 输出: 网卡名称，或失败时退出脚本
# ============================================
detect_interface() {
    local iface=""

    # 优先级 1: 手动指定
    if [ -n "${INTERFACE}" ]; then
        iface="${INTERFACE}"
        if [ ! -d "/sys/class/net/${iface}" ]; then
            log ERROR "指定的网卡 ${iface} 不存在于 /sys/class/net/"
            exit 1
        fi
        log INFO "使用手动指定的网卡: ${iface}"
        echo "${iface}"
        return 0
    fi

    # 方法 A: ip route get (首选)
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [ -n "${iface}" ] && [ -d "/sys/class/net/${iface}" ]; then
        log INFO "自动检测到网卡 (方法A): ${iface}"
        echo "${iface}"
        return 0
    fi

    # 方法 B: ip route show default (容器兼容)
    iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [ -n "${iface}" ] && [ -d "/sys/class/net/${iface}" ]; then
        log INFO "自动检测到网卡 (方法B): ${iface}"
        echo "${iface}"
        return 0
    fi

    # 方法 C: 读取 /proc/net/route
    iface=$(awk 'NR>1 && $2=="00000000" {print $1}' /proc/net/route 2>/dev/null | head -1)
    if [ -n "${iface}" ] && [ -d "/sys/class/net/${iface}" ]; then
        log INFO "自动检测到网卡 (方法C): ${iface}"
        echo "${iface}"
        return 0
    fi

    # 方法 D: vnstat 已有数据库
    iface=$(vnstat --iflist 2>/dev/null | head -1)
    if [ -n "${iface}" ] && [ -d "/sys/class/net/${iface}" ]; then
        log INFO "自动检测到网卡 (方法D): ${iface}"
        echo "${iface}"
        return 0
    fi

    log ERROR "无法检测到外网网卡，请使用 -i 参数手动指定"
    exit 1
}

# ============================================
# 函数: get_billing_start_date
# 说明: 计算当前结算周期的起始日期
# 参数: 无 (使用全局 RESET_DAY)
# 输出: "YYYY-MM-DD" 格式的起始日期
# ============================================
get_billing_start_date() {
    local cur_year cur_month cur_day
    cur_year=$(date '+%Y')
    cur_month=$(date '+%m')
    cur_day=$(date '+%d')

    # 去除前导零，避免被解析为八进制
    cur_month=$((10#${cur_month}))
    cur_day=$((10#${cur_day}))

    local start_year start_month
    if [ "${cur_day}" -ge "${RESET_DAY}" ]; then
        start_year="${cur_year}"
        start_month="${cur_month}"
    else
        start_month=$((cur_month - 1))
        start_year="${cur_year}"
        if [ "${start_month}" -eq 0 ]; then
            start_month=12
            start_year=$((cur_year - 1))
        fi
    fi

    # 修正结算日不超过起始月的最大天数
    local max_day
    max_day=$(get_max_day_of_month "${start_year}" "${start_month}")
    local start_day="${RESET_DAY}"
    if [ "${RESET_DAY}" -gt "${max_day}" ]; then
        start_day="${max_day}"
    fi

    echo "${start_year}-$(printf '%02d' ${start_month})-$(printf '%02d' "${start_day}")"
}

# ============================================
# 函数: get_billing_end_date
# 说明: 计算当前结算周期的结束日期 (即今天)
# 参数: 无
# 输出: "YYYY-MM-DD" 格式的结束日期
# ============================================
get_billing_end_date() {
    date '+%Y-%m-%d'
}

# ============================================
# 函数: parse_vnstat_json
# 说明: 解析 vnstat JSON 输出，支持 jq -> python3 -> python2 -> awk fallback 链
# 参数: $1 = JSON 字符串, $2 = jq 查询表达式
# 输出: 查询结果
# 返回: 0 成功, 1 失败
# ============================================
parse_vnstat_json() {
    local json="$1"
    local query="$2"

    # 方法 1: jq
    if command -v jq >/dev/null 2>&1; then
        echo "${json}" | jq -r "${query}" 2>/dev/null
        return 0
    fi

    # 方法 2: python3
    if command -v python3 >/dev/null 2>&1; then
        # 使用更安全的方式: 直接传递原始 json，让 python 处理
        python3 -c "
import sys, json
data = json.load(sys.stdin)
# vnstat JSON 字段是单数: month 和 day
iface = data['interfaces'][0]
months = iface['traffic'].get('month', [])
days = iface['traffic'].get('day', [])
print(json.dumps({'months': months, 'days': days}))
" <<< "${json}" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d))" 2>/dev/null
        return 0
    fi

    # 方法 3: python2
    if command -v python2 >/dev/null 2>&1; then
        python2 -c "
import sys, json
data = json.load(sys.stdin)
iface = data['interfaces'][0]
months = iface['traffic'].get('months', [])
days = iface['traffic'].get('days', [])
print(json.dumps({'months': months, 'days': days}))
" <<< "${json}" 2>/dev/null
        return 0
    fi

    # 方法 4: awk/sed 手动解析 (极简 fallback，提取 rx 和 tx)
    log WARN "无 jq/python，使用文本解析 fallback"
    # 尝试提取所有 rx 和 tx 数值 (不精确但尽量兼容)
    echo "${json}" | tr ',' '\n' | grep -E '"rx"|"tx"' | sed 's/.*"rx": *\([0-9]*\).*/\1/; s/.*"tx": *\([0-9]*\).*/\1/'
    return 0
}

# ============================================
# 函数: get_traffic_data
# 说明: 获取当前结算周期内的累计 RX/TX 流量 (bytes)
# 参数: 无
# 输出: 两行数据: RX_bytes TX_bytes (失败时输出 -1 -1)
# 返回: 0 成功, 1 失败
# ============================================
get_traffic_data() {
    local start_date end_date
    start_date=$(get_billing_start_date)
    end_date=$(get_billing_end_date)
    local rx=0 tx=0
    local json_data=""
    local vnstat_timeout=15

    # 情况 1: 快速路径 - 结算日为 1 号且当前是当月 (start_date 月 = 当月)
    local start_month
    start_month=$(echo "${start_date}" | cut -d'-' -f2)
    start_month=$((10#${start_month}))
    local cur_month
    cur_month=$(date '+%m')
    cur_month=$((10#${cur_month}))

    if [ "${RESET_DAY}" -eq 1 ] && [ "${start_month}" -eq "${cur_month}" ]; then
        # 使用 vnstat --json m 获取月度数据
        json_data=$(timeout "${vnstat_timeout}" vnstat --json m 2>/dev/null) || true

        if [ -z "${json_data}" ]; then
            log WARN "vnstat 月度数据返回空，尝试使用缓存"
            if [ -n "${CACHED_RX}" ] && [ -n "${CACHED_TX}" ]; then
                echo "${CACHED_RX} ${CACHED_TX}"
                return 0
            fi
            echo "-1 -1"
            return 1
        fi

        # 使用 jq 获取最后一个月的数据 (单次调用，避免多次管道导致数据丢失)
        if command -v jq >/dev/null 2>&1; then
            local cur_year cur_month
            cur_year=$(date '+%Y')
            cur_month=$(date '+%m')

            # 用 jq 直接提取年月 RX TX，若任一字段为 null 则输出 null
            local month_result
            month_result=$(echo "${json_data}" | jq -r '[
                .interfaces[0].traffic.month[-1].date.year,
                .interfaces[0].traffic.month[-1].date.month,
                .interfaces[0].traffic.month[-1].rx,
                .interfaces[0].traffic.month[-1].tx
            ] | if .[0] == null or .[1] == null or .[2] == null then null else . end | @tsv' 2>/dev/null)

            if [ -n "${month_result}" ] && [ "${month_result}" != "null" ]; then
                local m_year m_month
                m_year=$(echo "${month_result}" | cut -f1)
                m_month=$(echo "${month_result}" | cut -f2)
                rx=$(echo "${month_result}" | cut -f3)
                tx=$(echo "${month_result}" | cut -f4)

                # 去除前导零进行数值比较
                m_year=$((10#${m_year}))
                m_month=$((10#${m_month}))
                cur_month=$((10#${cur_month}))

                if [ "${m_year}" -eq "${cur_year}" ] && [ "${m_month}" -eq "${cur_month}" ]; then
                    # 更新缓存
                    CACHED_RX="${rx}"
                    CACHED_TX="${tx}"
                    echo "${rx} ${tx}"
                    return 0
                fi
            fi
        fi

        # jq 不可用或月度数据不匹配，fallback 到日数据累加
        log WARN "月度数据不可用，fallback 到日数据累加"
    fi

    # 情况 2: 日数据累加 (所有情况)
    json_data=$(timeout "${vnstat_timeout}" vnstat --json d 2>/dev/null) || true

    if [ -z "${json_data}" ]; then
        log WARN "vnstat 日数据返回空"
        if [ -n "${CACHED_RX}" ] && [ -n "${CACHED_TX}" ]; then
            echo "${CACHED_RX} ${CACHED_TX}"
            return 0
        fi
        echo "-1 -1"
        return 1
    fi

    # 解析日数据并累加
    if command -v jq >/dev/null 2>&1; then
        # 使用进程替换替代管道 subshell，避免数据丢失
        # jq 输出 tab 分隔的 year month day rx tx，由 bash 做日期过滤
        local day_count=0
        while IFS= read -r line; do
            [ -z "${line}" ] && continue
            # line 格式 (tab 分隔): year month day rx tx
            local d_year d_month d_day d_rx d_tx
            d_year=$(echo "${line}" | cut -f1)
            d_month=$(echo "${line}" | cut -f2)
            d_day=$(echo "${line}" | cut -f3)
            d_rx=$(echo "${line}" | cut -f4)
            d_tx=$(echo "${line}" | cut -f5)

            [ -z "${d_year}" ] || [ -z "${d_month}" ] || [ -z "${d_day}" ] && continue

            # 去除前导零 (bash 会将 "04" 当作八进制，所以用 10# 前缀)
            d_year=$((10#${d_year}))
            d_month=$((10#${d_month}))
            d_day=$((10#${d_day}))

            # 构造 YYYY-MM-DD 格式日期字符串用于比较
            local date_str
            date_str=$(printf '%04d-%02d-%02d' ${d_year} ${d_month} ${d_day})

            # 日期在结算周期内则累加
            if [ ! "${date_str}" \< "${start_date}" ] && [ ! "${date_str}" \> "${end_date}" ]; then
                rx=$((rx + d_rx))
                tx=$((tx + d_tx))
                day_count=$((day_count + 1))
            fi
        done < <(echo "${json_data}" | jq -r '.interfaces[0].traffic.day[] | [.date.year, .date.month, .date.day, .rx, .tx] | @tsv' 2>/dev/null)

        if [ ${day_count} -eq 0 ]; then
            log WARN "vnstat 日数据数组为空或无匹配日期"
            if [ -n "${CACHED_RX}" ] && [ -n "${CACHED_TX}" ]; then
                echo "${CACHED_RX} ${CACHED_TX}"
                return 0
            fi
            echo "-1 -1"
            return 1
        fi
    fi

    # 情况 2: 日数据累加 (所有情况)
    json_data=$(timeout "${vnstat_timeout}" vnstat --json d 2>/dev/null) || true

    if [ -z "${json_data}" ]; then
        log WARN "vnstat 日数据返回空"
        if [ -n "${CACHED_RX}" ] && [ -n "${CACHED_TX}" ]; then
            echo "${CACHED_RX} ${CACHED_TX}"
            return 0
        fi
        echo "-1 -1"
        return 1
    fi

    # 解析日数据并累加
    if command -v jq >/dev/null 2>&1; then
        # 使用进程替换替代管道 subshell，避免数据丢失
        # jq -c 输出每行一个 JSON 对象，直接通过 process substitution 传给 while 循环
        local day_count=0
        while IFS= read -r day_entry; do
            [ -z "${day_entry}" ] && continue

            local d_year d_month d_day
            d_year=$(echo "${day_entry}" | jq -r '.date.year // empty' 2>/dev/null)
            d_month=$(echo "${day_entry}" | jq -r '.date.month // empty' 2>/dev/null)
            d_day=$(echo "${day_entry}" | jq -r '.date.day // empty' 2>/dev/null)

            if [ -z "${d_year}" ] || [ -z "${d_month}" ] || [ -z "${d_day}" ]; then
                continue
            fi

            local date_str
            date_str="${d_year}-$(printf '%02d' $((10#${d_month})))-$(printf '%02d' $((10#${d_day})))"

            if [ ! "${date_str}" \< "${start_date}" ] && [ ! "${date_str}" \> "${end_date}" ]; then
                local d_rx d_tx
                d_rx=$(echo "${day_entry}" | jq -r '.rx // 0' 2>/dev/null)
                d_tx=$(echo "${day_entry}" | jq -r '.tx // 0' 2>/dev/null)
                rx=$((rx + d_rx))
                tx=$((tx + d_tx))
                day_count=$((day_count + 1))
            fi
        done < <(echo "${json_data}" | jq -c '.interfaces[0].traffic.day[]?' 2>/dev/null)

        if [ ${day_count} -eq 0 ]; then
            log WARN "vnstat 日数据数组为空或无匹配日期"
            if [ -n "${CACHED_RX}" ] && [ -n "${CACHED_TX}" ]; then
                echo "${CACHED_RX} ${CACHED_TX}"
                return 0
            fi
            echo "-1 -1"
            return 1
        fi
    else
        # python3 fallback 解析
        if command -v python3 >/dev/null 2>&1; then
            local result
            result=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
days = data['interfaces'][0]['traffic'].get('day', [])
rx = 0
tx = 0
for day in days:
    d = day['date']
    date_str = f\"{d['year']}-{d['month']:02d}-{d['day']:02d}\"
    if '${start_date}' <= date_str <= '${end_date}':
        rx += day.get('rx', 0)
        tx += day.get('tx', 0)
print(f'{rx} {tx}')
" <<< "${json_data}" 2>/dev/null)

            if [ -n "${result}" ]; then
                echo "${result}"
                # 更新缓存
                read -r rx tx <<< "${result}"
                CACHED_RX="${rx}"
                CACHED_TX="${tx}"
                return 0
            fi
        elif command -v python2 >/dev/null 2>&1; then
            local result
            result=$(python2 -c "
import sys, json
data = json.load(sys.stdin)
days = data['interfaces'][0]['traffic'].get('day', [])
rx = 0
tx = 0
for day in days:
    d = day['date']
    date_str = '{:04d}-{:02d}-{:02d}'.format(d['year'], d['month'], d['day'])
    if '${start_date}' <= date_str <= '${end_date}':
        rx += day.get('rx', 0)
        tx += day.get('tx', 0)
print('{} {}'.format(rx, tx))
" <<< "${json_data}" 2>/dev/null)

            if [ -n "${result}" ]; then
                echo "${result}"
                read -r rx tx <<< "${result}"
                CACHED_RX="${rx}"
                CACHED_TX="${tx}"
                return 0
            fi
        fi

        log ERROR "无法解析 vnstat JSON 数据，缺少 jq/python"
        if [ -n "${CACHED_RX}" ] && [ -n "${CACHED_TX}" ]; then
            echo "${CACHED_RX} ${CACHED_TX}"
            return 0
        fi
        echo "-1 -1"
        return 1
    fi

    # 更新缓存
    CACHED_RX="${rx}"
    CACHED_TX="${tx}"
    echo "${rx} ${tx}"
    return 0
}

# ============================================
# 函数: calculate_ratio
# 说明: 计算当前结算周期内的 RX/TX 比例
# 参数: 无
# 输出: 比例值 (浮点数), 或 -1 表示 N/A
# ============================================
calculate_ratio() {
    local data
    data=$(get_traffic_data)
    local ret=$?

    if [ ${ret} -ne 0 ]; then
        log WARN "流量数据获取失败，比例 N/A"
        echo "-1"
        return 0
    fi

    local rx tx
    read -r rx tx <<< "${data}"

    if [ "${rx}" = "-1" ] && [ "${tx}" = "-1" ]; then
        log WARN "无有效流量数据，比例 N/A"
        echo "-1"
        return 0
    fi

    if [ "${tx}" -eq 0 ]; then
        if [ "${rx}" -eq 0 ]; then
            log WARN "RX 和 TX 均为 0，比例 N/A"
            echo "-1"
        else
            log INFO "TX 为 0，RX > 0，比例视为极大值"
            echo "999999"
        fi
        return 0
    fi

    local ratio
    ratio=$(awk "BEGIN {printf \"%.2f\", ${rx}/${tx}}")
    echo "${ratio}"
}

# ============================================
# 函数: acquire_script_lock
# 说明: 获取脚本单实例锁 (PID 文件)
# 参数: 无
# 输出: 无 (成功) 或错误信息 (失败)
# ============================================
acquire_script_lock() {
    local dir
    dir=$(dirname "${SCRIPT_PIDFILE}")
    mkdir -p "${dir}" 2>/dev/null || true

    if [ -f "${SCRIPT_PIDFILE}" ]; then
        local old_pid
        old_pid=$(cat "${SCRIPT_PIDFILE}" 2>/dev/null)
        if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
            log ERROR "已有实例在运行 (PID: ${old_pid})"
            exit 1
        fi
        # 僵尸 PID 文件，清理
        rm -f "${SCRIPT_PIDFILE}"
    fi

    echo $$ > "${SCRIPT_PIDFILE}"
    log INFO "已获取脚本锁，PID: $$"
}

# ============================================
# 函数: release_all_locks
# 说明: 释放所有锁并清理 PID 文件，同时终止 curl 子进程
# 参数: 无
# 输出: 无
# ============================================
release_all_locks() {
    # 杀死 curl 子进程 (如果有)
    if [ -f "${CURL_PIDFILE}" ]; then
        local curl_pid
        curl_pid=$(cat "${CURL_PIDFILE}" 2>/dev/null)
        if [ -n "${curl_pid}" ]; then
            kill "${curl_pid}" 2>/dev/null || true
        fi
        rm -f "${CURL_PIDFILE}"
    fi
    rm -f "${CURL_PIDFILE}.stat"
    rm -f "${SCRIPT_PIDFILE}"
    log INFO "已清理所有锁，退出脚本"
    exit 0
}

# 注册退出清理
trap release_all_locks EXIT INT TERM

# ============================================
# 函数: is_curl_running
# 说明: 检查 curl 下载进程是否正在运行
# 参数: 无
# 返回: 0 正在运行, 1 未运行
# ============================================
is_curl_running() {
    if [ -f "${CURL_PIDFILE}" ]; then
        local curl_pid
        curl_pid=$(cat "${CURL_PIDFILE}" 2>/dev/null)
        if [ -n "${curl_pid}" ] && kill -0 "${curl_pid}" 2>/dev/null; then
            return 0  # 正在运行
        fi
        # 进程已退出，清理 PID 文件
        rm -f "${CURL_PIDFILE}"
    fi
    return 1  # 未运行
}

# ============================================
# 函数: start_curl_download
# 说明: 后台启动 curl 下载进程
# 参数: $1 = 下载 URL
# 输出: 无
# ============================================
start_curl_download() {
    local url="$1"
    local dir
    dir=$(dirname "${CURL_PIDFILE}")
    mkdir -p "${dir}" 2>/dev/null || true

    # 使用临时文件存储 curl 统计信息
    local stat_file
    stat_file="${dir}/curl_stat_$$"

    (
        curl -L --limit-rate "${LIMIT_RATE}" \
             --connect-timeout "${CONNECT_TIMEOUT}" \
             --max-time "${MAX_DOWNLOAD_TIME}" \
             -o /dev/null -s -w "http_code=%{http_code} size=%{size_download} time=%{time_total}" \
             "${url}" > "${stat_file}" 2>/dev/null
        echo " exit_code=$?" >> "${stat_file}"
    ) &

    local pid=$!
    echo "${pid}" > "${CURL_PIDFILE}"
    echo "${stat_file}" > "${CURL_PIDFILE}.stat"
}

# ============================================
# 函数: traffic_balance
# 说明: 触发流量平衡下载
# 参数: 无
# 输出: 无
# ============================================
traffic_balance() {
    local idx url
    idx=$((RANDOM % 6))
    url="${DOWNLOAD_URLS[${idx}]}"

    log INFO "开始流量平衡下载: ${url}"
    start_curl_download "${url}"

    if [ "${TELEGRAM_ENABLED}" = true ]; then
        # 可选: 发送 Telegram 通知
        :
    fi
}

# ============================================
# 函数: check_download_status
# 说明: 检查 curl 下载是否完成，并记录结果
# 参数: 无
# 输出: 无
# ============================================
check_download_status() {
    if [ ! -f "${CURL_PIDFILE}" ]; then
        return
    fi

    local curl_pid
    curl_pid=$(cat "${CURL_PIDFILE}" 2>/dev/null)
    if [ -z "${curl_pid}" ]; then
        rm -f "${CURL_PIDFILE}"
        return
    fi

    # 检查进程是否仍在运行
    if kill -0 "${curl_pid}" 2>/dev/null; then
        return  # 仍在运行
    fi

    # 进程已结束，获取退出码和统计信息
    local stat_file
    stat_file="${CURL_PIDFILE}.stat"
    local stat=""
    local exit_code=1

    if [ -f "${stat_file}" ]; then
        stat=$(cat "${stat_file}" 2>/dev/null)
        # 提取退出码
        exit_code=$(echo "${stat}" | sed -n 's/.*exit_code=\([0-9]*\).*/\1/p')
        [ -z "${exit_code}" ] && exit_code=1
    fi

    # 解析 HTTP 状态码和下载大小 (避免 grep -P，使用 sed)
    local http_code size
    http_code=$(echo "${stat}" | sed -n 's/.*http_code=\([0-9]*\).*/\1/p')
    size=$(echo "${stat}" | sed -n 's/.*size=\([0-9]*\).*/\1/p')
    [ -z "${http_code}" ] && http_code="0"
    [ -z "${size}" ] && size="0"

    if [ "${exit_code}" -eq 0 ] && [ -n "${http_code}" ] && { [ "${http_code:0:1}" = "2" ] || [ "${http_code:0:1}" = "3" ]; }; then
        log INFO "下载完成 - HTTP ${http_code}, 下载量 $(human_bytes "${size}")"
    else
        log ERROR "下载失败 - HTTP ${http_code}, 退出码 ${exit_code}"
    fi

    # 清理
    rm -f "${CURL_PIDFILE}" "${stat_file}"
}

# ============================================
# 函数: send_telegram_message
# 说明: 发送 Telegram 文本消息
# 参数: $1 = chat_id, $2 = 文本内容
# 输出: 无
# ============================================
send_telegram_message() {
    local chat_id="$1"
    local text="$2"

    # URL 编码 (优先 python，fallback 到 sed)
    local encoded_text
    encoded_text=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${text}'''))" 2>/dev/null || \
                   python2 -c "import urllib; print(urllib.quote('''${text}'''))" 2>/dev/null || \
                   echo "${text}" | sed 's/ /%20/g;s/\n/%0A/g')

    curl -s --connect-timeout 10 --max-time 15 \
        -X POST "${API_BASE}/sendMessage" \
        -d "chat_id=${chat_id}&text=${encoded_text}" \
        -o /dev/null 2>/dev/null || true
}

# ============================================
# 函数: send_traffic_report
# 说明: 发送流量报告到指定 Telegram chat
# 参数: $1 = chat_id
# 输出: 无
# ============================================
send_traffic_report() {
    local chat_id="$1"
    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local start_date end_date
    start_date=$(get_billing_start_date)
    end_date=$(get_billing_end_date)

    local data rx tx ratio
    data=$(get_traffic_data)
    read -r rx tx <<< "${data}"

    local ratio_str status
    ratio=$(calculate_ratio)

    if [ "${ratio}" = "-1" ]; then
        ratio_str="N/A (无数据)"
        status="无数据"
    else
        ratio_str="${ratio}"
        if is_curl_running; then
            status="平衡中"
        else
            status="监控中"
        fi
    fi

    local rx_human tx_human
    rx_human=$(human_bytes "${rx}")
    tx_human=$(human_bytes "${tx}")

    local curl_status
    if is_curl_running; then
        curl_status="运行中"
    else
        curl_status="空闲"
    fi

    local report
    report=$(cat <<EOF
[流量报告] ${hostname}
时间: ${timestamp}
网卡: ${INTERFACE}
结算周期: ${start_date} ~ ${end_date}
----------------------------
下载(RX): ${rx_human}
上传(TX): ${tx_human}
RX/TX比例: ${ratio_str}
----------------------------
状态: ${status}
脚本PID: $$
curl下载: ${curl_status}
上次检查: ${timestamp}
EOF
)

    send_telegram_message "${chat_id}" "${report}"
}

# ============================================
# 函数: parse_and_handle_updates
# 说明: 解析 Telegram updates 并处理 /traffic 命令
# 参数: $1 = API 响应 JSON
# 输出: 无
# ============================================
parse_and_handle_updates() {
    local response="$1"

    if command -v jq >/dev/null 2>&1; then
        local updates
        updates=$(echo "${response}" | jq -c '.result[]?' 2>/dev/null)
        [ -z "${updates}" ] && return

        while IFS= read -r update; do
            [ -z "${update}" ] && continue

            local update_id
            update_id=$(echo "${update}" | jq -r '.update_id // empty' 2>/dev/null)
            [ -z "${update_id}" ] && continue

            if [ "${update_id}" -gt "${LAST_UPDATE_ID}" ]; then
                LAST_UPDATE_ID="${update_id}"
            fi

            local from_id
            from_id=$(echo "${update}" | jq -r '.message.from.id // empty' 2>/dev/null)
            if [ -z "${from_id}" ] || [ "${from_id}" != "${TELEGRAM_ALLOWED_USER_ID}" ]; then
                continue
            fi

            local text chat_id
            text=$(echo "${update}" | jq -r '.message.text // ""' 2>/dev/null)
            chat_id=$(echo "${update}" | jq -r '.message.chat.id // empty' 2>/dev/null)

            # 去除首尾空格
            text=$(echo "${text}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # 检查 /traffic 命令 (可能带 @bot_username)
            if echo "${text}" | grep -qE '^/traffic(@[A-Za-z0-9_]+)?$'; then
                if [ -n "${chat_id}" ]; then
                    send_traffic_report "${chat_id}"
                fi
            fi
        done <<< "${updates}"
    else
        # python3 fallback
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import sys, json
response = json.load(sys.stdin)
for update in response.get('result', []):
    update_id = update.get('update_id', 0)
    if update_id > ${LAST_UPDATE_ID}:
        # 无法直接修改 shell 变量，改为输出新的 LAST_UPDATE_ID
        pass
    msg = update.get('message', {})
    from_id = str(msg.get('from', {}).get('id', ''))
    if from_id != '${TELEGRAM_ALLOWED_USER_ID}':
        continue
    text = msg.get('text', '').strip()
    chat_id = msg.get('chat', {}).get('id', '')
    if text.startswith('/traffic'):
        print(f'CMD:traffic CHAT:{chat_id}')
" <<< "${response}" 2>/dev/null | while IFS= read -r line; do
                if echo "${line}" | grep -q '^CMD:traffic CHAT:'; then
                    local cid
                    cid="${line//CMD:traffic CHAT:/}"
                    [ -n "${cid}" ] && send_traffic_report "${cid}"
                fi
            done
        fi
    fi
}

# ============================================
# 函数: poll_telegram
# 说明: 轮询 Telegram Bot API 获取更新
# 参数: 无
# 输出: 无
# ============================================
poll_telegram() {
    local offset=$((LAST_UPDATE_ID + 1))
    local response

    response=$(curl -s --connect-timeout 10 --max-time "$((TG_POLL_INTERVAL + 5))" \
        "${API_BASE}/getUpdates?offset=${offset}&timeout=${TG_POLL_INTERVAL}" 2>/dev/null) || true

    if [ -z "${response}" ]; then
        return  # 网络错误，跳过
    fi

    # 检查 ok 字段 (不使用 grep -P)
    if ! echo "${response}" | grep -q '"ok":true'; then
        return
    fi

    parse_and_handle_updates "${response}"
}

# ============================================
# 函数: detect_init_system
# 说明: 检测当前系统的 init 系统类型
# 参数: 无
# 输出: systemd|openrc|sysv|unknown
# ============================================
detect_init_system() {
    # 方法 1: 检查 PID 1
    local init
    init=$(cat /proc/1/comm 2>/dev/null || ps --no-headers -o comm 1 2>/dev/null)

    if [ "${init}" = "systemd" ]; then
        echo "systemd"
        return
    fi

    # 方法 2: 命令检测
    if command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
        return
    fi

    if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        echo "openrc"
        return
    fi

    # 方法 3: 检查 /etc/init.d 与 chkconfig/update-rc.d
    if [ -d /etc/init.d ] && { command -v chkconfig >/dev/null 2>&1 || command -v update-rc.d >/dev/null 2>&1; }; then
        echo "sysv"
        return
    fi

    # 最终 fallback
    echo "unknown"
}

# ============================================
# 函数: install_service
# 说明: 安装为系统服务 (systemd/OpenRC/SysV)
# 参数: $@ = 用户传入的脚本参数 (去除 --install-service)
# 输出: 安装日志
# ============================================
install_service() {
    if [ "$(id -u)" -ne 0 ]; then
        log ERROR "安装服务需要 root 权限"
        exit 1
    fi

    # 安装依赖
    install_dependencies || exit 1

    # 检测网卡
    local iface
    iface=$(detect_interface)
    INTERFACE="${iface}"

    # 确认 vnstatd 运行
    local vnstatd_running=false
    if systemctl is-active vnstat >/dev/null 2>&1 || \
       systemctl is-active vnstatd >/dev/null 2>&1; then
        vnstatd_running=true
    elif command -v rc-service >/dev/null 2>&1 && rc-service vnstatd status >/dev/null 2>&1; then
        vnstatd_running=true
    fi

    if [ "${vnstatd_running}" = false ]; then
        log INFO "尝试启动 vnstatd..."
        systemctl start vnstat >/dev/null 2>&1 || \
        systemctl start vnstatd >/dev/null 2>&1 || \
        { command -v rc-service >/dev/null 2>&1 && rc-service vnstatd start >/dev/null 2>&1; } || true
    fi

    # 确认网卡已被 vnstat 监控
    if ! vnstat --json d -i "${iface}" --limit 1 >/dev/null 2>&1; then
        log INFO "网卡 ${iface} 未被 vnstat 监控，正在添加..."
        vnstat -i "${iface}" --add >/dev/null 2>&1 || true

        # 等待最多 60 秒直到有数据
        local waited=0
        while [ ${waited} -lt 60 ]; do
            if vnstat --json d -i "${iface}" --limit 1 >/dev/null 2>&1; then
                log INFO "vnstat 数据已就绪"
                break
            fi
            sleep 5
            waited=$((waited + 5))
            log INFO "等待 vnstat 数据... (${waited}s)"
        done

        if [ ${waited} -ge 60 ]; then
            log WARN "等待 vnstat 数据超时，继续安装服务"
        fi
    fi

    # 复制脚本到 /usr/local/bin
    local script_src
    script_src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    cp "${script_src}" /usr/local/bin/traffic_balance.sh
    chmod +x /usr/local/bin/traffic_balance.sh
    log INFO "脚本已复制到 /usr/local/bin/traffic_balance.sh"

    # 收集用户参数 (去除 --install-service)
    local user_args=()
    for arg in "$@"; do
        if [ "${arg}" != "--install-service" ]; then
            user_args+=("${arg}")
        fi
    done

    local init_system
    init_system=$(detect_init_system)
    log INFO "检测到 init 系统: ${init_system}"

    case "${init_system}" in
        systemd)
            # 构建 ExecStart 参数字符串
            local exec_args=""
            for arg in "${user_args[@]}"; do
                exec_args="${exec_args} '${arg}'"
            done

            cat > /etc/systemd/system/traffic-balance.service <<EOF
[Unit]
Description=Traffic Balance Monitor Service
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/traffic_balance.sh${exec_args}
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload
            systemctl enable traffic-balance
            systemctl start traffic-balance
            log INFO "systemd 服务已安装并启动"
            ;;

        openrc)
            local args_str=""
            for arg in "${user_args[@]}"; do
                args_str="${args_str} ${arg}"
            done

            cat > /etc/init.d/traffic-balance <<EOF
#!/sbin/openrc-run
description="Traffic Balance Monitor"
command="/usr/local/bin/traffic_balance.sh"
command_args="${args_str}"
command_background=true
pidfile="/var/run/traffic_balance.pid"
EOF

            chmod +x /etc/init.d/traffic-balance
            rc-update add traffic-balance default
            rc-service traffic-balance start
            log INFO "OpenRC 服务已安装并启动"
            ;;

        sysv)
            local args_str=""
            for arg in "${user_args[@]}"; do
                args_str="${args_str} '${arg}'"
            done

            cat > /etc/init.d/traffic-balance <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          traffic-balance
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Traffic Balance Monitor
# Description:       Monitor traffic ratio and balance automatically
### END INIT INFO

NAME="traffic-balance"
DAEMON="/usr/local/bin/traffic_balance.sh"
PIDFILE="/var/run/traffic_balance.pid"

start() {
    echo "Starting \${NAME}..."
    if [ -f "\${PIDFILE}" ] && kill -0 "\$(cat \${PIDFILE})" 2>/dev/null; then
        echo "\${NAME} is already running"
        return 0
    fi
    nohup \${DAEMON}${args_str} > /dev/null 2>&1 &
    echo \$! > "\${PIDFILE}"
    echo "\${NAME} started"
}

stop() {
    echo "Stopping \${NAME}..."
    if [ -f "\${PIDFILE}" ]; then
        kill "\$(cat \${PIDFILE})" 2>/dev/null || true
        rm -f "\${PIDFILE}"
        rm -f "\${PIDFILE%.pid}_curl.pid"
    fi
    echo "\${NAME} stopped"
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status)
        if [ -f "\${PIDFILE}" ] && kill -0 "\$(cat \${PIDFILE})" 2>/dev/null; then
            echo "\${NAME} is running"
        else
            echo "\${NAME} is not running"
        fi
        ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF

            chmod +x /etc/init.d/traffic-balance

            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d traffic-balance defaults
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --add traffic-balance
            fi

            service traffic-balance start
            log INFO "SysV init 服务已安装并启动"
            ;;

        unknown)
            log WARN "无法识别 init 系统，请手动配置持久化"
            echo "建议的 cron 条目:"
            echo "@reboot /usr/local/bin/traffic_balance.sh ${user_args[*]}"
            ;;
    esac
}

# ============================================
# 函数: uninstall_service
# 说明: 卸载系统服务
# 参数: 无
# 输出: 卸载日志
# ============================================
uninstall_service() {
    if [ "$(id -u)" -ne 0 ]; then
        log ERROR "卸载服务需要 root 权限"
        exit 1
    fi

    local init_system
    init_system=$(detect_init_system)
    log INFO "检测到 init 系统: ${init_system}"

    case "${init_system}" in
        systemd)
            systemctl stop traffic-balance >/dev/null 2>&1 || true
            systemctl disable traffic-balance >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/traffic-balance.service
            systemctl daemon-reload
            log INFO "systemd 服务已卸载"
            ;;

        openrc)
            rc-service traffic-balance stop >/dev/null 2>&1 || true
            rc-update del traffic-balance >/dev/null 2>&1 || true
            rm -f /etc/init.d/traffic-balance
            log INFO "OpenRC 服务已卸载"
            ;;

        sysv)
            service traffic-balance stop >/dev/null 2>&1 || true
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d -f traffic-balance remove >/dev/null 2>&1 || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --del traffic-balance >/dev/null 2>&1 || true
            fi
            rm -f /etc/init.d/traffic-balance
            log INFO "SysV init 服务已卸载"
            ;;

        unknown)
            log WARN "无法识别 init 系统，手动清理可能必要"
            ;;
    esac

    # 清理脚本文件和 PID 文件
    rm -f /usr/local/bin/traffic_balance.sh
    rm -f /var/run/traffic_balance.pid
    rm -f /var/run/traffic_balance_curl.pid
    log INFO "服务文件已清理"
}

# ============================================
# 函数: self_test
# 说明: 执行自检测试
# 参数: 无
# 输出: 测试结果到 stdout
# ============================================
self_test() {
    local errors=0

    echo "========================================"
    echo "Traffic Balance 自检测试"
    echo "========================================"

    # 1. bash 版本检查
    echo ""
    echo "[1/7] Bash 版本检查"
    local bash_major
    bash_major=${BASH_VERSION%%.*}
    if [ "${bash_major}" -ge 4 ]; then
        echo "  PASS: Bash ${BASH_VERSION}"
    else
        echo "  FAIL: Bash ${BASH_VERSION} (需要 >= 4.0)"
        errors=$((errors + 1))
    fi

    # 2. 必要命令检查
    echo ""
    echo "[2/7] 必要命令检查"
    for cmd in curl vnstat; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            echo "  PASS: ${cmd} 已安装"
        else
            echo "  FAIL: ${cmd} 未安装"
            errors=$((errors + 1))
        fi
    done

    if command -v jq >/dev/null 2>&1; then
        echo "  PASS: jq 已安装 (JSON 解析首选)"
    elif command -v python3 >/dev/null 2>&1; then
        echo "  PASS: python3 已安装 (JSON 解析 fallback)"
    elif command -v python2 >/dev/null 2>&1; then
        echo "  PASS: python2 已安装 (JSON 解析 fallback)"
    else
        echo "  WARN: 无 jq/python3/python2，JSON 解析能力受限"
    fi

    # 3. vnstatd 运行状态
    echo ""
    echo "[3/7] vnstatd 运行状态"
    local vnstatd_ok=false
    if systemctl is-active vnstat >/dev/null 2>&1 || \
       systemctl is-active vnstatd >/dev/null 2>&1; then
        vnstatd_ok=true
    elif command -v rc-service >/dev/null 2>&1 && rc-service vnstatd status >/dev/null 2>&1; then
        vnstatd_ok=true
    fi

    if [ "${vnstatd_ok}" = true ]; then
        echo "  PASS: vnstatd 正在运行"
    else
        echo "  WARN: vnstatd 未检测到运行中 (可能不影响，如果数据已存在)"
    fi

    # 4. 网卡检测
    echo ""
    echo "[4/7] 网卡检测"
    local detected_iface
    detected_iface=$(detect_interface 2>/dev/null)
    if [ -n "${detected_iface}" ]; then
        echo "  PASS: 检测到网卡 ${detected_iface}"
    else
        echo "  FAIL: 无法检测网卡"
        errors=$((errors + 1))
    fi

    # 5. Telegram Token 格式 (如果配置了)
    echo ""
    echo "[5/7] Telegram Token 格式"
    if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
        if echo "${TELEGRAM_BOT_TOKEN}" | grep -qE '^[0-9]{8,10}:[A-Za-z0-9_-]{35,}$'; then
            echo "  PASS: Telegram Bot Token 格式合法"
        else
            echo "  FAIL: Telegram Bot Token 格式不合法"
            errors=$((errors + 1))
        fi

        if [ -n "${TELEGRAM_ALLOWED_USER_ID}" ]; then
            echo "  PASS: Telegram User ID 已配置"
        else
            echo "  WARN: Telegram User ID 未配置，/traffic 命令不会响应"
        fi
    else
        echo "  SKIP: Telegram Bot Token 未配置"
    fi

    # 6. 配置文件加载
    echo ""
    echo "[6/7] 配置文件加载"
    echo "  RESET_DAY=${RESET_DAY}"
    echo "  INTERFACE=${INTERFACE:-'(自动检测)'}"
    echo "  LIMIT_RATE=${LIMIT_RATE}"
    echo "  CHECK_INTERVAL=${CHECK_INTERVAL}"
    echo "  TG_POLL_INTERVAL=${TG_POLL_INTERVAL}"
    echo "  PASS: 配置加载完成"

    # 7. 权限检查
    echo ""
    echo "[7/7] 权限检查"
    if [ "$(id -u)" -eq 0 ]; then
        echo "  PASS: 当前为 root 用户，完整功能可用"
    else
        echo "  WARN: 当前非 root 用户，服务安装等功能受限"
    fi

    # 总结
    echo ""
    echo "========================================"
    if [ ${errors} -eq 0 ]; then
        echo "自检通过，未发现错误"
    else
        echo "自检发现 ${errors} 个错误，请修复后再运行"
    fi
    echo "========================================"

    return ${errors}
}

# ============================================
# 函数: show_help
# 说明: 显示帮助信息
# 参数: 无
# 输出: 帮助文本到 stdout
# ============================================
show_help() {
    cat <<EOF
Traffic Balance Monitor v${SCRIPT_VERSION}

用法: $0 [选项]

选项:
  -d, --reset-day DAY      月度流量结算日 (1-31, 默认: 1)
  -i, --interface IFACE    手动指定外网网卡 (默认: 自动检测)
  -l, --limit-rate SPEED   curl 下载限速 (默认: 1M)
  -c, --config FILE        指定配置文件路径
      --install-service    安装为系统服务 (需要 root)
      --uninstall-service  卸载系统服务 (需要 root)
      --self-test          执行自检测试
  -h, --help               显示此帮助信息

配置文件查找顺序:
  1. -c 命令行指定的路径
  2. \$HOME/.config/traffic_balance/config
  3. /etc/traffic_balance.conf

示例:
  前台运行:           $0 -d 15 -l 2M
  安装服务:           sudo $0 --install-service -d 15
  卸载服务:           sudo $0 --uninstall-service
  自检测试:           $0 --self-test
EOF
}

# ============================================
# 函数: load_config
# 说明: 加载配置文件，按优先级合并配置
# 参数: $1 = 命令行指定的配置文件路径 (可选)
# 输出: 无 (设置全局变量)
# ============================================
load_config() {
    local config_file="$1"
    local loaded=false

    # 查找配置文件
    if [ -n "${config_file}" ] && [ -f "${config_file}" ]; then
        # 1. 命令行指定
        # shellcheck source=/dev/null
        source "${config_file}"
        loaded=true
        log INFO "已加载配置文件: ${config_file}"
    elif [ -f "${HOME}/.config/traffic_balance/config" ]; then
        # 2. 用户级配置
        # shellcheck source=/dev/null
        source "${HOME}/.config/traffic_balance/config"
        loaded=true
        log INFO "已加载用户配置文件: ${HOME}/.config/traffic_balance/config"
    elif [ -f /etc/traffic_balance.conf ]; then
        # 3. 系统级配置
        # shellcheck source=/dev/null
        source /etc/traffic_balance.conf
        loaded=true
        log INFO "已加载系统配置文件: /etc/traffic_balance.conf"
    fi

    if [ "${loaded}" = false ]; then
        log WARN "配置文件不存在，使用默认值"
    fi
}

# ============================================
# 函数: setup_telegram
# 说明: 检查并初始化 Telegram 功能
# 参数: 无
# 输出: 无 (设置全局变量 TELEGRAM_ENABLED, API_BASE)
# ============================================
setup_telegram() {
    TELEGRAM_ENABLED=false
    API_BASE=""

    if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_ALLOWED_USER_ID}" ]; then
        if echo "${TELEGRAM_BOT_TOKEN}" | grep -qE '^[0-9]{8,10}:[A-Za-z0-9_-]{35,}$'; then
            TELEGRAM_ENABLED=true
            API_BASE="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
            log INFO "Telegram 通知已启用"
        else
            log WARN "Telegram Bot Token 格式不合法，跳过 Telegram 功能"
        fi
    else
        log INFO "Telegram 未配置，跳过轮询"
    fi
}

# ============================================
# 函数: main_loop
# 说明: 脚本主循环，持续监控流量和轮询 Telegram
# 参数: 无
# 输出: 无
# ============================================
main_loop() {
    acquire_script_lock

    # 安装依赖 (如果不是服务安装模式)
    install_dependencies || true

    # 检测网卡
    local iface
    iface=$(detect_interface)
    INTERFACE="${iface}"

    # 确认 vnstatd 运行
    local vnstatd_ok=false
    if systemctl is-active vnstat >/dev/null 2>&1 || \
       systemctl is-active vnstatd >/dev/null 2>&1; then
        vnstatd_ok=true
    elif command -v rc-service >/dev/null 2>&1 && rc-service vnstatd status >/dev/null 2>&1; then
        vnstatd_ok=true
    fi

    if [ "${vnstatd_ok}" = false ]; then
        log WARN "vnstatd 未检测到运行中，尝试启动..."
        systemctl start vnstat >/dev/null 2>&1 || \
        systemctl start vnstatd >/dev/null 2>&1 || \
        { command -v rc-service >/dev/null 2>&1 && rc-service vnstatd start >/dev/null 2>&1; } || true
    fi

    # 检查 Telegram
    setup_telegram

    if [ "${TELEGRAM_ENABLED}" = true ]; then
        LAST_UPDATE_ID=0
    fi

    # 初始化循环变量
    local last_check=0
    CACHED_RX=""
    CACHED_TX=""

    log INFO "主循环启动 - 网卡: ${INTERFACE}, 结算日: ${RESET_DAY}, 检查间隔: ${CHECK_INTERVAL}s"

    while true; do
        local now
        now=$(date +%s)

        # b. 流量检查 (每 CHECK_INTERVAL 秒)
        if [ $((now - last_check)) -ge "${CHECK_INTERVAL}" ]; then
            local ratio
            ratio=$(calculate_ratio)

            if [ "${ratio}" = "-1" ]; then
                # N/A，不做任何操作
                :
            elif [ "${ratio}" = "999999" ]; then
                # TX 为 0，RX > 0，不触发平衡但记录
                log INFO "流量比例: 极大值 (TX=0)，监控中"
            elif awk "BEGIN {exit !(${ratio} <= 2.0)}"; then
                if ! is_curl_running; then
                    log INFO "流量比例 ${ratio} <= 2.0，触发流量平衡"
                    traffic_balance
                fi
            else
                log INFO "流量比例 ${ratio} > 2.0，监控中"
            fi

            last_check="${now}"
        fi

        # c. 检查 curl 是否完成
        check_download_status

        # d. Telegram 轮询
        if [ "${TELEGRAM_ENABLED}" = true ]; then
            poll_telegram
        fi

        # e. 休眠
        if [ "${TELEGRAM_ENABLED}" = true ]; then
            sleep 0.5
        else
            sleep 1
        fi
    done
}

# ============================================
# 主流程入口
# ============================================
main() {
    # 保存原始参数 (用于服务安装)
    local original_args=("$@")

    local config_path=""
    local install_service_flag=false
    local uninstall_service_flag=false
    local self_test_flag=false

    # 参数解析
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--reset-day)
                RESET_DAY="$2"
                shift 2
                ;;
            -i|--interface)
                INTERFACE="$2"
                shift 2
                ;;
            -l|--limit-rate)
                LIMIT_RATE="$2"
                shift 2
                ;;
            -c|--config)
                config_path="$2"
                shift 2
                ;;
            --install-service)
                install_service_flag=true
                shift
                ;;
            --uninstall-service)
                uninstall_service_flag=true
                shift
                ;;
            --self-test)
                self_test_flag=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done

    # 设置路径
    setup_paths

    # 加载配置
    load_config "${config_path}"

    # 非 root 运行时提示
    if [ "$(id -u)" -ne 0 ]; then
        log WARN "当前非 root 运行，服务安装等功能受限"
    fi

    # 处理服务模式
    if [ "${install_service_flag}" = true ]; then
        install_service "${original_args[@]}"
        exit 0
    fi

    if [ "${uninstall_service_flag}" = true ]; then
        uninstall_service
        exit 0
    fi

    if [ "${self_test_flag}" = true ]; then
        self_test
        exit $?
    fi

    # 正常启动主循环
    main_loop
}

# 执行主函数
main "$@"
