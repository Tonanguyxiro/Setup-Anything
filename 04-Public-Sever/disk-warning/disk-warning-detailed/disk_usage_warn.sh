#!/bin/sh
# 磁盘用量告警：满足下面任一条件时，登录提示同时显示两部分信息
#   触发条件（任一即可）：
#      - 任一磁盘使用率超过阈值（默认 90%）
#      - 当前用户 /home 超过 100G
#      - 当前用户数据盘合计超过 500G
#   第一部分 全局信息：
#      - /home 与各数据盘的使用率、剩余容量
#      - 每块盘占用最多的三个用户，各一行
#      - 系统级缓存/临时目录占用，提示清理
#   第二部分 当前用户信息：
#      - 各盘用量、较大的一级目录与大文件、长期未改动的目录、缓存临时文件
#      - 汇总成清理建议
#
# 用法：
#   disk_usage_warn.sh           登录展示（只读缓存，毫秒级）
#   disk_usage_warn.sh --scan    扫描并生成缓存（root，由 systemd timer 调用）
#   disk_usage_warn.sh --self    实时重算并显示“当前用户”部分（普通用户可用）
#   disk_usage_warn.sh --test    实时重算并显示全部内容，忽略阈值，不写缓存
#   disk_usage_warn.sh --report  打印本次扫描的完整报告（不重新扫描）
#   disk_usage_warn.sh --roots   打印识别到的家目录与数据盘（换服务器时先确认）
#   disk_usage_warn.sh --help    显示帮助
#   附加 --force 可忽略用户阈值强制输出（配合 --self 使用）
#   进度只在手动运行（stderr 是终端）时显示，--progress/--quiet 可强制开关
#
# 配置：/etc/disk-usage-warn.conf（阈值、目录位置），也可用同名环境变量临时覆盖

set -u

# ---------------------------------------------------------------- 配置

CONFIG_FILE=${CONFIG_FILE:-/etc/disk-usage-warn.conf}

# 优先级：环境变量 > 配置文件 > 默认值。
# 配置文件是普通赋值，会盖掉环境变量，所以先把环境里显式给的值存下来，读完配置再盖回去。
CONFIG_VARS="THRESHOLD USER_HOME_WARN_GB USER_DATA_WARN_GB CACHE_WARN_GB BIG_FILE_GB
OLD_DAYS HOME_ROOT DATA_ROOTS DATA_ROOT_NAMES STATE_DIR DU_TIMEOUT SCAN_PARALLEL SCAN_JOBS"

for _v in $CONFIG_VARS; do
    eval "_env_$_v=\${$_v-}"
done

[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

for _v in $CONFIG_VARS; do
    eval "[ -n \"\${_env_$_v}\" ] && $_v=\${_env_$_v}"
done

# 磁盘使用率告警阈值（百分比），任一盘超过即显示全局信息
THRESHOLD=${THRESHOLD:-90}
# 用户 /home 用量阈值（GiB），超过即显示当前用户信息
USER_HOME_WARN_GB=${USER_HOME_WARN_GB:-100}
# 用户数据盘合计用量阈值（GiB），超过即显示当前用户信息
USER_DATA_WARN_GB=${USER_DATA_WARN_GB:-500}
# 单个系统缓存目录超过该值（GiB）时提示清理
CACHE_WARN_GB=${CACHE_WARN_GB:-10}
# 列为“大文件”的下限（GiB）
BIG_FILE_GB=${BIG_FILE_GB:-5}
# 超过该天数未改动的目录视为“很早下的”
OLD_DAYS=${OLD_DAYS:-90}

HOME_ROOT=${HOME_ROOT:-/home}
# 数据盘根目录；留空表示自动探测（独立挂载的非系统分区）
DATA_ROOTS=${DATA_ROOTS:-}
# 自动探测时额外尝试的目录名
DATA_ROOT_NAMES=${DATA_ROOT_NAMES:-"data data1 data2 data3 ssd ssd1 nvme scratch shared"}

STATE_DIR=${STATE_DIR:-/var/lib/disk-usage-warn}
GLOBAL_REPORT=${GLOBAL_REPORT:-$STATE_DIR/global.txt}
GLOBAL_BRIEF=${GLOBAL_BRIEF:-$STATE_DIR/global.brief}
USER_REPORT_DIR=${USER_REPORT_DIR:-$STATE_DIR/users}
# du 单次扫描的超时时间（秒），0 表示不限制
DU_TIMEOUT=${DU_TIMEOUT:-0}
# 各块盘并行扫描（不同物理设备互不抢 IO）；设 0 退回串行
SCAN_PARALLEL=${SCAN_PARALLEL:-1}
# 单块盘内部按一级目录分片的并行度；1 表示不分片。
# RAID / NVMe 上调到 4~8 通常能快 2~4 倍，但会明显占 IO，确认不影响业务再调。
SCAN_JOBS=${SCAN_JOBS:-1}

MODE=login
FORCE=0
PROGRESS_FORCE=auto

while [ "$#" -gt 0 ]; do
    case "$1" in
        --scan|--update-log) MODE=scan ;;
        --roots|--show-roots) MODE=roots ;;
        --report|--full) MODE=report ;;
        --self) MODE=self ;;
        --test|test) MODE=test; FORCE=1 ;;
        --force) FORCE=1 ;;
        --progress) PROGRESS_FORCE=on ;;
        --quiet|--no-progress) PROGRESS_FORCE=off ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf "未知参数：%s（--help 查看用法）\n" "$1" >&2
            exit 1
            ;;
    esac
    shift
done

# ---------------------------------------------------------------- 基础工具

C_RED='\033[31m'; C_BRED='\033[1;31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
C_BYELLOW='\033[1;33m'; C_BLUE='\033[1;34m'; C_CYAN='\033[36m'; C_BCYAN='\033[1;36m'
C_GRAY='\033[90m'; C_OFF='\033[0m'

# 进度条只服务手动操作：stderr 是终端、且不是登录展示时才开。
# systemd timer 跑 --scan 时 stderr 不是终端 → 自动静默，不会往 journal 里灌刷新字符。
case "$PROGRESS_FORCE" in
    on) PROGRESS=1 ;;
    off) PROGRESS=0 ;;
    *)
        if [ -t 2 ] && [ "$MODE" != login ]; then
            PROGRESS=1
        else
            PROGRESS=0
        fi
        ;;
esac

# 直接输出的模式（--self/--test/--roots）写进管道或文件时自动去色；
# --scan 始终带色，登录展示时再按需要去色。
# login 模式也要判断：缓存文件里的颜色由 display_file 负责剥离，
# 但“完整报告：…”这类直接打印的行用的是 C_* 变量。
if [ -n "${NO_COLOR:-}" ] || { [ "$MODE" != scan ] && [ ! -t 1 ]; }; then
    C_RED=; C_BRED=; C_GREEN=; C_YELLOW=; C_BYELLOW=; C_BLUE=; C_CYAN=; C_BCYAN=; C_GRAY=; C_OFF=
fi

cecho() { # cecho 颜色 格式 参数...
    color=$1
    fmt=$2
    shift 2
    printf "%b" "$color"
    printf "$fmt" "$@"
    printf "%b" "$C_OFF"
}

rule() { cecho "$C_GRAY" "%s\n" "---------------------------------------------------------------"; }

# KiB -> 人类可读
human_kb() {
    awk -v kb="${1:-0}" 'BEGIN {
        if (kb >= 1073741824) printf "%.1fT\n", kb / 1073741824
        else if (kb >= 10485760) printf "%.0fG\n", kb / 1048576
        else if (kb >= 1048576) printf "%.1fG\n", kb / 1048576
        else if (kb >= 1024) printf "%.0fM\n", kb / 1024
        else printf "%dK\n", kb
    }'
}

gb_to_kb() { awk -v gb="$1" 'BEGIN { printf "%d\n", gb * 1048576 }'; }

now_epoch() { date +%s; }

days_ago() { # days_ago mtime_epoch
    awk -v m="${1:-0}" -v n="$(now_epoch)" 'BEGIN { printf "%d\n", (n - m) / 86400 }'
}

truncate_text() {
    awk -v text="$1" -v max="$2" 'BEGIN {
        if (length(text) > max) print substr(text, 1, max - 1) "~"
        else print text
    }'
}

# 按终端显示宽度补空格（中文/emoji 占 2 列）
pad() { # pad 文本 宽度（左对齐）
    LC_ALL=C awk -v s="$1" -v w="$2" 'BEGIN {
        tmp = s
        wide = gsub(/[\302-\364]/, "", tmp)
        gsub(/[\200-\277]/, "", tmp)
        n = w - (length(tmp) + 2 * wide)
        if (n < 0) n = 0
        printf "%s%*s", s, n, ""
    }'
}

rpad() { # rpad 文本 宽度（右对齐）
    LC_ALL=C awk -v s="$1" -v w="$2" 'BEGIN {
        tmp = s
        wide = gsub(/[\302-\364]/, "", tmp)
        gsub(/[\200-\277]/, "", tmp)
        n = w - (length(tmp) + 2 * wide)
        if (n < 0) n = 0
        printf "%*s%s", n, "", s
    }'
}

# 表格一行：参数为 "宽度 单元格" 成对出现，最后可跟一个不补齐的尾列
# 宽度前加 r 表示右对齐（数字列用），列间以 "| " 分隔
trow() {
    LC_ALL=C awk '
        function dispwidth(s,   tmp, wide) {
            tmp = s
            wide = gsub(/[\302-\364]/, "", tmp)   # UTF-8 首字节：中文/emoji 占 2 列
            gsub(/[\200-\277]/, "", tmp)          # 续字节
            return length(tmp) + 2 * wide
        }
        BEGIN {
            out = ""
            tail = 0
            i = 1
            while (i < ARGC) {
                if (i + 1 >= ARGC) {              # 尾列原样输出（可以为空）
                    out = out ARGV[i]
                    tail = 1
                    break
                }
                spec = ARGV[i]
                cell = ARGV[i + 1]
                i += 2
                right = 0
                if (substr(spec, 1, 1) == "r") {
                    right = 1
                    spec = substr(spec, 2)
                }
                w = spec + 0
                if (right) {
                    n = w - 1 - dispwidth(cell)
                    if (n < 0) n = 0
                    out = out sprintf("%*s%s ", n, "", cell)
                } else {
                    n = w - dispwidth(cell)
                    if (n < 1) n = 1              # 超长内容也至少留一个空格
                    out = out cell sprintf("%*s", n, "")
                }
                out = out "| "
            }
            # 没给尾列时去掉多余的列分隔符
            if (!tail && substr(out, length(out) - 1) == "| ") out = substr(out, 1, length(out) - 2)
            print out
        }
    ' "$@"
}

# 表头下的分隔线：参数为各列宽度，与 trow 一一对应
tsep() {
    LC_ALL=C awk 'BEGIN {
        out = ""
        for (i = 1; i < ARGC; i++) {
            w = ARGV[i]
            sub(/^r/, "", w)
            out = out sprintf("%*s", w + 0, "")
            if (i < ARGC - 1) out = out "+-"
        }
        gsub(/ /, "-", out)
        print out
    }' "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 进度显示（仅手动运行）

SCAN_START=$(date +%s)

elapsed_text() { # elapsed_text 起始秒
    awk -v s="${1:-$SCAN_START}" -v n="$(date +%s)" 'BEGIN {
        d = n - s
        printf "%02d:%02d\n", int(d / 60), d % 60
    }'
}

pstage() { # pstage 步骤 总步数 文案
    [ "$PROGRESS" -eq 1 ] || return 0
    printf "\033[36m[%s/%s]\033[0m %s\n" "$1" "$2" "$3" >&2
}

pline() { # pline 单行状态（原地刷新）
    [ "$PROGRESS" -eq 1 ] || return 0
    printf "\r\033[K  %s" "$1" >&2
}

pdone() { # pdone 结束语，清掉刷新行
    [ "$PROGRESS" -eq 1 ] || return 0
    printf "\r\033[K  %s\n" "$1" >&2
}

# 进度条：pbar 已完成 总数 宽度
pbar() {
    awk -v done="$1" -v total="$2" -v width="${3:-20}" 'BEGIN {
        if (total <= 0) total = 1
        pct = done * 100 / total
        if (pct > 100) pct = 100
        filled = int(width * pct / 100)
        bar = ""
        for (i = 0; i < width; i++) bar = bar (i < filled ? "#" : "-")
        printf "[%s] %3d%%\n", bar, pct
    }'
}

# 低优先级执行，避免扫描影响线上任务
nice_prefix() {
    if have ionice; then
        printf "nice -n 19 ionice -c 3"
    else
        printf "nice -n 19"
    fi
}

nice_run() {
    if have ionice; then
        nice -n 19 ionice -c 3 "$@"
    else
        nice -n 19 "$@"
    fi
}

du_scan() { # du_scan 深度 目录 -> "KB<TAB>路径"
    depth=$1
    target=$2
    if [ "$DU_TIMEOUT" -gt 0 ] && have timeout; then
        nice_run timeout "$DU_TIMEOUT" du -x --max-depth="$depth" -- "$target" 2>/dev/null
    else
        nice_run du -x --max-depth="$depth" -- "$target" 2>/dev/null
    fi
}

# ---------------------------------------------------------------- 磁盘信息

# df 单行：挂载点 使用率 已用KB 总量KB 剩余KB
df_info() {
    df -P -k -- "$1" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $6, $5, $3, $2, $4 }'
}

usage_percent() { df_info "$1" | awk '{print $2}'; }

# 自动探测数据盘：
#   1) 独立挂载的本地磁盘分区（排除 tmpfs 等伪文件系统与系统目录）
#   2) 加上常见的数据目录名（有些机器 /data 只是根分区下的普通目录）
# 配置里写了 DATA_ROOTS 就完全以配置为准。
discover_data_roots() {
    if [ -n "$DATA_ROOTS" ]; then
        for root in $DATA_ROOTS; do
            [ -d "$root" ] && printf "%s\n" "$root"
        done
        return
    fi

    {
        df -P -k --local \
            -x tmpfs -x devtmpfs -x squashfs -x overlay -x iso9660 -x efivarfs -x ramfs \
            2>/dev/null | awk 'NR > 1 {print $6}'
        for name in $DATA_ROOT_NAMES; do
            [ -d "/$name" ] && printf "%s\n" "/$name"
        done
    } | sort -u | while IFS= read -r mount; do
        case "$mount" in
            /|/boot*|/run*|/dev*|/sys*|/proc*|/tmp|/tmp/*|/var*|/usr*|/etc*|/opt|/snap*|/media*|\
            "$HOME_ROOT"|"$HOME_ROOT"/*) continue ;;
        esac
        [ -d "$mount" ] || continue
        printf "%s\n" "$mount"
    done
}

# 打印识别结果，换服务器时先跑这个确认
print_roots() {
    cecho "$C_BLUE" "🔎 目录识别结果（换服务器后先确认这一项）\n"
    cecho "$C_BLUE" "%s\n" "$(trow 10 "类型" 14 "路径" r7 "使用率" r16 "已用 / 总量" "文件系统")"
    cecho "$C_GRAY" "%s\n" "$(tsep 10 14 7 16 20)"

    printf "%s\n" "$ALL_ROOTS" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ "$root" = "$HOME_ROOT" ] && kind="家目录" || kind="数据盘"
        info=$(df_info "$root")
        fs=$(df -P -k -- "$root" 2>/dev/null | awk 'NR == 2 {print $1}')
        if [ -n "$info" ]; then
            set -- $info
            cecho "$C_CYAN" "%s\n" "$(trow 10 "$kind" 14 "$root" r7 "${2}%" \
                r16 "$(human_kb "$3") / $(human_kb "$4")" "${fs:--}")"
        else
            cecho "$C_GRAY" "%s\n" "$(trow 10 "$kind" 14 "$root" r7 "-" r16 "-" "无法读取")"
        fi
    done

    printf "\n"
    if [ -n "$DATA_ROOTS" ]; then
        cecho "$C_GRAY" "数据盘来自配置 DATA_ROOTS=\"%s\"\n" "$DATA_ROOTS"
    else
        cecho "$C_GRAY" "数据盘为自动探测：独立挂载的本地分区 + 常见目录名（%s）\n" "$DATA_ROOT_NAMES"
        cecho "$C_GRAY" "识别不对时在 %s 里写死，例如：DATA_ROOTS=\"/data /ssd\"\n" "$CONFIG_FILE"
    fi
    cecho "$C_GRAY" "注意：NFS 等网络盘不会被识别（df --local），需要时请显式写入 DATA_ROOTS\n"
}

DATA_ROOT_LIST=$(discover_data_roots)
ALL_ROOTS=$(printf "%s\n%s\n" "$HOME_ROOT" "$DATA_ROOT_LIST" | awk 'NF && !seen[$0]++')

any_root_above_threshold() {
    printf "%s\n" "$ALL_ROOTS" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        usage=$(usage_percent "$root")
        [ -n "$usage" ] || continue
        [ "$usage" -ge "$THRESHOLD" ] && printf "hit\n"
    done | grep -q hit
}

# /home 下的真实用户目录
list_home_user_dirs() {
    dirs=
    if have getent; then
        dirs=$(getent passwd | awk -F: -v root="$HOME_ROOT" '$6 ~ "^" root "/[^/]+$" {print $6}' | sort -u)
    fi
    # getent 查不到（如目录与账号不对应）时退回按目录枚举
    [ -n "$dirs" ] || dirs=$(find "$HOME_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    printf "%s\n" "$dirs" | while IFS= read -r home_dir; do
        [ -d "$home_dir" ] && [ ! -L "$home_dir" ] && printf "%s\n" "$home_dir"
    done
}

# ---------------------------------------------------------------- 扫描缓存

WORK=
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

init_work() {
    [ -n "$WORK" ] && return 0
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/disk-usage-warn.XXXXXX") || exit 1
}

# 取 du 缓存中相对 root 的第 N 层条目："KB<TAB>路径"
depth_lines() { # depth_lines 缓存文件 root 层数
    awk -F'\t' -v root="$2" -v want="$3" '
        {
            path = $2
            if (path == root) next
            if (substr(path, 1, length(root) + 1) != root "/") next   # 必须真的在 root 下
            rel = substr(path, length(root) + 2)
            n = split(rel, parts, "/")
            if (n == want) print $1 "\t" path
        }
    ' "$1" 2>/dev/null
}

# root 下的一级普通文件（du 只统计目录，需单独补上）
first_level_files() { # first_level_files root
    find "$1"/ -maxdepth 1 -xdev -type f -printf '%k\t%p\n' 2>/dev/null
}

path_key() { # path_key 路径 -> 可做文件名的串
    printf "%s" "$1" | tr -c 'a-zA-Z0-9' '-'
}

data_root_cache() { # data_root_cache root -> 缓存文件名
    printf "%s/data%s.du" "$WORK" "$(path_key "$1")"
}

root_cache() { # root_cache root -> 缓存文件名（家目录固定为 home.du）
    if [ "$1" = "$HOME_ROOT" ]; then
        printf "%s/home.du" "$WORK"
    else
        data_root_cache "$1"
    fi
}

root_shard_dir() { # root_shard_dir root -> 分片目录
    printf "%s/shard%s" "$WORK" "$(path_key "$1")"
}

# 与 root 同一个文件系统的一级条目（挂载到别处的目录不算，避免重复统计）
list_same_device_entries() { # list_same_device_entries root
    root_dev=$(stat -c '%d' -- "$1" 2>/dev/null) || return 0
    find "$1"/ -maxdepth 1 -mindepth 1 ! -type l -print 2>/dev/null |
        while IFS= read -r entry; do
            dev=$(stat -c '%d' -- "$entry" 2>/dev/null) || continue
            [ "$dev" = "$root_dev" ] && printf "%s\n" "$entry"
        done
}

count_entries() { # count_entries root -> 一级条目数（进度条分母）
    list_same_device_entries "$1" | wc -l
}

# 扫描一块盘到缓存文件；SCAN_JOBS>1 时按一级目录分片并行
scan_root_to_cache() { # scan_root_to_cache 深度 root 缓存文件
    depth=$1
    root=$2
    out=$3
    shard=$(root_shard_dir "$root")

    if [ "$SCAN_JOBS" -gt 1 ] && have xargs; then
        mkdir -p "$shard"
        # 每个一级目录单独一个 du，各写各的分片文件，避免并发写同一文件串行与错行。
        # 分片是从一级目录“里面”开始扫的，du -x 挡不住挂载点（例如 /home/shared 其实是
        # /ssd 的绑定挂载），所以这里按设备号过滤，复刻 du -x 的不跨挂载点语义。
        list_same_device_entries "$root" |
            xargs -r -d '\n' -P "$SCAN_JOBS" -I{} \
                sh -c 'p=$1; d=$2; s=$3; n=$(printf "%s" "$p" | tr -c "a-zA-Z0-9" "-")
                       '"$(nice_prefix)"' du -x --max-depth="$d" -- "$p" > "$s/$n.du" 2>/dev/null' \
                _ {} "$((depth - 1))" "$shard"
        cat "$shard"/*.du > "$out" 2>/dev/null || : > "$out"
    elif have stdbuf; then
        # 行缓冲：让进度条能实时数到已扫完的一级目录
        nice_run stdbuf -oL du -x --max-depth="$depth" -- "$root" > "$out" 2>/dev/null || :
    else
        du_scan "$depth" "$root" > "$out"
    fi
}

# 已扫完的一级条目数：分片模式数文件，单进程模式数缓存里的一级行
scan_done_count() { # scan_done_count root 缓存文件
    shard=$(root_shard_dir "$1")
    if [ -d "$shard" ]; then
        find "$shard" -maxdepth 1 -name '*.du' 2>/dev/null | wc -l
    else
        depth_lines "$2" "$1" 1 2>/dev/null | wc -l
    fi
}

jobs_running() { # jobs_running "pid1 pid2 ..."
    for pid in $1; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# 扫描期间的进度刷新（仅手动运行）
watch_scan() { # watch_scan "pids" 作业表
    [ "$PROGRESS" -eq 1 ] || return 0
    pids=$1
    jobs_file=$2

    while jobs_running "$pids"; do
        status=
        nroots=0
        last_done=0
        last_total=0
        while IFS="$(printf '\t')" read -r root cache total; do
            [ -n "${root:-}" ] || continue
            nroots=$((nroots + 1))
            done_n=$(scan_done_count "$root" "$cache")
            last_done=$done_n
            last_total=$total
            status="$status$(basename "$root") ${done_n}/${total}  "
        done < "$jobs_file"

        if [ "$nroots" -eq 1 ]; then
            pline "$(pbar "$last_done" "$last_total" 24 | tr -d '\n')  $status$(elapsed_text)"
        else
            pline "扫描中  $status $(elapsed_text)"
        fi
        sleep 1
    done
}

# 扫描所有盘，生成 du 缓存与 owners.tsv（root<TAB>owner<TAB>KB<TAB>条目<TAB>mtime）
build_caches() {
    init_work

    list_home_user_dirs > "$WORK/userhomes.txt" 2>/dev/null || : > "$WORK/userhomes.txt"

    all_roots=$(printf "%s\n%s\n" "$HOME_ROOT" "$DATA_ROOT_LIST" | awk 'NF && !seen[$0]++')
    : > "$WORK/jobs.tsv"
    pids=

    old_ifs=$IFS
    IFS='
'
    for root in $all_roots; do
        IFS=$old_ifs
        [ -d "$root" ] || { IFS='
'; continue; }
        if [ "$root" = "$HOME_ROOT" ]; then
            depth=4          # /home/<用户>/<一级目录>/<缓存子目录>
        else
            depth=3          # /盘/<一级目录>/<子目录>/<孙目录>（容器目录下钻后仍要有下一层）
        fi
        cache=$(root_cache "$root")
        printf "%s\t%s\t%s\n" "$root" "$cache" "$(count_entries "$root")" >> "$WORK/jobs.tsv"

        if [ "$SCAN_PARALLEL" -eq 1 ]; then
            scan_root_to_cache "$depth" "$root" "$cache" &
            pids="$pids $!"
        else
            scan_root_to_cache "$depth" "$root" "$cache"
        fi
        IFS='
'
    done
    IFS=$old_ifs

    if [ -n "$pids" ]; then
        watch_scan "$pids" "$WORK/jobs.tsv"
        wait
        pdone "磁盘扫描完成，用时 $(elapsed_text)"
    fi

    # 数据盘一级条目的属主与 mtime（纯 stat，很快）
    : > "$WORK/owners.tsv"
    printf "%s\n" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        cache=$(root_cache "$root")
        {
            depth_lines "$cache" "$root" 1
            first_level_files "$root"
        } | while IFS="$(printf '\t')" read -r kb path; do
            [ -n "${path:-}" ] || continue
            attribute_entry "$root" "$cache" "$kb" "$path" >> "$WORK/owners.tsv"
        done
    done
}

# 把一个一级条目的用量记到属主名下。
# 像 /ssd/home、/data/bak 这种 root 名下的“容器目录”，里面装的其实是各用户自己的目录，
# 整块记到 root 头上毫无指导意义；所以当一个目录里有 2 个以上子目录属于别人时，
# 下钻一层按子目录各自的属主归集，剩余部分（散落文件）仍记在父目录属主名下。
attribute_entry() { # attribute_entry root 缓存 KB 路径
    ae_root=$1
    ae_cache=$2
    ae_kb=$3
    ae_path=$4

    meta=$(stat -c '%U %Y' -- "$ae_path" 2>/dev/null) || return 0
    ae_owner=${meta% *}
    ae_mtime=${meta#* }

    if [ -d "$ae_path" ]; then
        depth_lines "$ae_cache" "$ae_path" 1 > "$WORK/children.tmp" 2>/dev/null
        if [ -s "$WORK/children.tmp" ]; then
            foreign=0
            child_sum=0
            : > "$WORK/children.rows"
            while IFS="$(printf '\t')" read -r ckb cpath; do
                [ -n "${cpath:-}" ] || continue
                cmeta=$(stat -c '%U %Y' -- "$cpath" 2>/dev/null) || continue
                cowner=${cmeta% *}
                cmtime=${cmeta#* }
                [ "$cowner" = "$ae_owner" ] || foreign=$((foreign + 1))
                child_sum=$((child_sum + ckb))
                printf "%s\t%s\t%s\t%s\t%s\n" "$ae_root" "$cowner" "$ckb" "$cpath" "$cmtime" \
                    >> "$WORK/children.rows"
            done < "$WORK/children.tmp"

            if [ "$foreign" -ge 2 ]; then
                cat "$WORK/children.rows"
                rest=$((ae_kb - child_sum))
                if [ "$rest" -gt 0 ]; then
                    printf "%s\t%s\t%s\t%s\t%s\n" "$ae_root" "$ae_owner" "$rest" "$ae_path" "$ae_mtime"
                fi
                return 0
            fi
        fi
    fi

    printf "%s\t%s\t%s\t%s\t%s\n" "$ae_root" "$ae_owner" "$ae_kb" "$ae_path" "$ae_mtime"
}

# 某用户在某数据盘的用量（KB）
user_data_root_kb() { # user_data_root_kb 用户 root
    awk -F'\t' -v user="$1" -v root="$2" '$1 == root && $2 == user {sum += $3} END {printf "%d\n", sum + 0}' \
        "$WORK/owners.tsv" 2>/dev/null
}

user_data_total_kb() { # user_data_total_kb 用户
    awk -F'\t' -v user="$1" '$2 == user {sum += $3} END {printf "%d\n", sum + 0}' \
        "$WORK/owners.tsv" 2>/dev/null
}

user_home_kb() { # user_home_kb 用户
    awk -F'\t' -v path="$HOME_ROOT/$1" '$2 == path {print $1; exit}' "$WORK/home.du" 2>/dev/null
}

# ---------------------------------------------------------------- 第一部分：全局信息

print_overview() {
    cecho "$C_BLUE" "📊 磁盘总览\n"
    cecho "$C_BLUE" "%s\n" "$(trow 14 "挂载点" r7 "使用率" r15 "已用 / 总量" r8 "剩余" "状态")"
    cecho "$C_GRAY" "%s\n" "$(tsep 14 7 15 8 14)"

    printf "%s\n" "$ALL_ROOTS" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        info=$(df_info "$root")
        [ -n "$info" ] || continue
        set -- $info
        usage=$2
        if [ "$usage" -ge "$THRESHOLD" ]; then
            status="⚠ 已超过 ${THRESHOLD}%"
            color=$C_RED
        elif [ "$usage" -ge $((THRESHOLD - 10)) ]; then
            status="接近阈值"
            color=$C_YELLOW
        else
            status="正常"
            color=$C_GREEN
        fi
        cecho "$color" "%s\n" "$(trow 14 "$root" r7 "${usage}%" \
            r15 "$(human_kb "$3") / $(human_kb "$4")" r8 "$(human_kb "$5")" "$status")"
    done
}

# 某块盘占用最多的三个用户，返回三个单元格（制表符分隔）
top_users_cells() { # top_users_cells 数据来源命令的输出
    awk -F'\t' '
        BEGIN { OFS = "\t" }
        { cells[NR] = $0 }
        END {
            for (i = 1; i <= 3; i++) printf "%s%s", (cells[i] ? cells[i] : "-"), (i < 3 ? OFS : "\n")
        }
    '
}

home_top_users() {
    depth_lines "$WORK/home.du" "$HOME_ROOT" 1 |
        awk -F'\t' -v f="$WORK/userhomes.txt" '
            BEGIN { while ((getline line < f) > 0) users[line] = 1 }
            (length(users) == 0) || ($2 in users)
        ' |
        sort -nr | head -n 3 |
        while IFS="$(printf '\t')" read -r kb path; do
            [ -n "${path:-}" ] || continue
            printf "%s(%s)\n" "$(truncate_text "$(basename "$path")" 14)" "$(human_kb "$kb")"
        done | top_users_cells
}

# 数据盘按一级目录/文件的属主归集
data_top_users() { # data_top_users root
    awk -F'\t' -v root="$1" '$1 == root {sum[$2] += $3} END {for (o in sum) print sum[o] "\t" o}' \
        "$WORK/owners.tsv" 2>/dev/null | sort -nr | head -n 3 |
        while IFS="$(printf '\t')" read -r kb owner; do
            [ -n "${owner:-}" ] || continue
            printf "%s(%s)\n" "$(truncate_text "$owner" 14)" "$(human_kb "$kb")"
        done | top_users_cells
}

print_top_users() {
    cecho "$C_BYELLOW" "👥 各盘占用最多的三个用户\n"
    cecho "$C_BYELLOW" "%s\n" "$(trow 10 "磁盘" 20 "No.1" 20 "No.2" "No.3")"
    cecho "$C_GRAY" "%s\n" "$(tsep 10 20 20 20)"

    printf "%s\n%s\n" "$HOME_ROOT" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ "$root" = "$HOME_ROOT" ]; then
            cells=$(home_top_users)
        else
            cells=$(data_top_users "$root")
        fi
        [ -n "$cells" ] || cells="-	-	-"
        t1=$(printf "%s" "$cells" | cut -f1)
        t2=$(printf "%s" "$cells" | cut -f2)
        t3=$(printf "%s" "$cells" | cut -f3)
        cecho "$C_YELLOW" "%s\n" "$(trow 10 "$root" 20 "${t1:--}" 20 "${t2:--}" "${t3:--}")"
    done
    cecho "$C_GRAY" "    数据盘按一级目录/文件的属主归集，root 名下一般是公共数据集与模型\n"
}

# 系统级缓存 / 临时目录
system_cache_candidates() {
    printf "%s\n" /tmp /var/tmp /var/cache /var/log /var/lib/docker /var/lib/containers
}

cache_hint() { # cache_hint 路径
    case "$1" in
        /tmp|/var/tmp) printf "清理 7 天前的残留：sudo find %s -xdev -mindepth 1 -mtime +7 -delete\n" "$1" ;;
        /var/log) printf "清理日志：sudo journalctl --vacuum-time=7d\n" ;;
        /var/cache) printf "清理包管理缓存：sudo dnf clean all（或 apt clean）\n" ;;
        /var/lib/docker) printf "清理无用镜像与构建缓存：sudo docker system prune -a\n" ;;
        /var/lib/containers) printf "清理无用镜像：sudo podman system prune -a\n" ;;
        *) printf "确认无运行中任务后清理\n" ;;
    esac
}

print_system_cache() {
    cache_warn_kb=$(gb_to_kb "$CACHE_WARN_GB")

    cecho "$C_BCYAN" "🧹 系统级缓存 / 临时目录（超过 %sG 提示清理）\n" "$CACHE_WARN_GB"
    cecho "$C_BCYAN" "%s\n" "$(trow 20 "目录" r8 "占用" "建议")"
    cecho "$C_GRAY" "%s\n" "$(tsep 20 8 46)"

    system_cache_candidates | while IFS= read -r path; do
        [ -d "$path" ] || continue
        if [ ! -r "$path" ]; then
            cecho "$C_GRAY" "%s\n" "$(trow 20 "$path" r8 "-" "无权限，请用 root 运行 --scan")"
            continue
        fi
        line=$(DU_TIMEOUT=120 du_scan 0 "$path" | head -n 1)
        kb=${line%%	*}
        case "$kb" in
            ''|*[!0-9]*)
                cecho "$C_GRAY" "%s\n" "$(trow 20 "$path" r8 "-" "扫描超时，可手动执行 sudo du -xsh $path")"
                continue
                ;;
        esac
        if [ "$kb" -ge "$cache_warn_kb" ]; then
            cecho "$C_RED" "%s\n" "$(trow 20 "$path" r8 "$(human_kb "$kb")" "⚠ $(cache_hint "$path")")"
        else
            cecho "$C_CYAN" "%s\n" "$(trow 20 "$path" r8 "$(human_kb "$kb")" "正常")"
        fi
    done

    if [ -d /dev/shm ]; then
        info=$(df_info /dev/shm)
        if [ -n "$info" ]; then
            set -- $info
            if [ "$2" -ge 50 ]; then
                cecho "$C_RED" "%s\n" "$(trow 20 "/dev/shm" r8 "$(human_kb "$3")" \
                    "⚠ 共享内存已用 $2%，确认无任务后清理 /dev/shm 残留")"
            fi
        fi
    fi
}

render_global() {
    stamp=$(date '+%Y-%m-%d %H:%M:%S')
    cecho "$C_BRED" "%s\n" "==============================================================="
    if any_root_above_threshold; then
        cecho "$C_BRED" "⚠️  磁盘告警：已有磁盘使用率超过 %s%%，请及时清理\n" "$THRESHOLD"
    else
        cecho "$C_BRED" "ℹ️  磁盘总览：当前所有磁盘都在 %s%% 以下\n" "$THRESHOLD"
    fi
    cecho "$C_GRAY" "    扫描时间：%s\n" "$stamp"
    cecho "$C_BRED" "%s\n" "==============================================================="
    printf "\n"
    print_overview
    printf "\n"
    print_top_users
    printf "\n"
    print_system_cache
}

# ---------------------------------------------------------------- 第二部分：当前用户信息

# 缓存 / 临时目录候选（相对用户家目录）
user_cache_candidates() {
    printf "%s\n" \
        ".cache" ".cache/huggingface" ".cache/pip" ".cache/uv" ".cache/torch" \
        ".cache/ms-playwright" ".conda/pkgs" ".npm" ".cargo/registry" \
        ".local/share/Trash" ".nv" ".vscode-server" ".cursor-server" ".ollama" \
        "miniconda3/pkgs" "anaconda3/pkgs" ".triton" ".keras"
}

# 这些目录计入“缓存合计”，彼此不重叠，避免父子目录重复累加
user_cache_roots() {
    printf "%s\n" ".cache" ".conda/pkgs" ".npm" ".cargo/registry" ".local/share/Trash" \
        ".nv" ".vscode-server" ".cursor-server" ".ollama" "miniconda3/pkgs" "anaconda3/pkgs"
}

home_du_lookup() { # home_du_lookup 绝对路径 -> KB（找不到则空）
    awk -F'\t' -v path="$1" '$2 == path {print $1; exit}' "$WORK/home.du" 2>/dev/null
}

cache_clean_hint() { # cache_clean_hint 相对路径
    case "$1" in
        .cache/huggingface) printf "huggingface-cli delete-cache，或删除 ~/.cache/huggingface/hub 下过期模型\n" ;;
        .cache/pip) printf "pip cache purge\n" ;;
        .cache/uv) printf "uv cache clean\n" ;;
        .conda/pkgs|miniconda3/pkgs|anaconda3/pkgs) printf "conda clean -a\n" ;;
        .npm) printf "npm cache clean --force\n" ;;
        .cargo/registry) printf "删除 ~/.cargo/registry/cache 与 src\n" ;;
        .local/share/Trash) printf "rm -rf ~/.local/share/Trash/*\n" ;;
        .cache/torch) printf "删除 ~/.cache/torch/hub 下过期权重\n" ;;
        .cache) printf "逐项确认后删除，或整体 rm -rf ~/.cache/*\n" ;;
        .vscode-server|.cursor-server) printf "删除 ~/%s/bin 下旧版本目录\n" "$1" ;;
        .ollama) printf "ollama rm <model> 删除不用的模型\n" ;;
        *) printf "确认不再需要后删除\n" ;;
    esac
}

# 事实收集：大文件 / 长期未动 / 缓存，只算一次，完整版与精简版共用
UF_BIG=; UF_OLD=; UF_CACHE=
USER_HOME_KB=0; USER_DATA_KB=0; USER_CACHE_TOTAL_KB=0

collect_user_facts() { # collect_user_facts 用户 home目录
    user=$1
    user_home=$2

    UF_BIG="$WORK/uf.big"
    UF_OLD="$WORK/uf.old"
    UF_CACHE="$WORK/uf.cache"

    USER_HOME_KB=$(home_du_lookup "$user_home")
    USER_HOME_KB=${USER_HOME_KB:-0}
    USER_DATA_KB=$(user_data_total_kb "$user")
    USER_DATA_KB=${USER_DATA_KB:-0}

    min_kb=$(gb_to_kb "$BIG_FILE_GB")

    # 剪枝：只进入体积本身就 ≥ 阈值的一级目录——小目录里装不下更大的文件
    targets=$(
        depth_lines "$WORK/home.du" "$user_home" 1 |
            awk -F'\t' -v min="$min_kb" '$1 >= min {print $2}'
        awk -F'\t' -v u="$user" -v min="$min_kb" '$2 == u && $3 >= min {print $4}' \
            "$WORK/owners.tsv" 2>/dev/null
    )

    # 第 4 列记下所属的一级目录，精简版据此把同一目录下的多个大文件合成一行
    {
        find "$user_home" -maxdepth 1 -xdev -type f -size +"${BIG_FILE_GB}"G \
            -printf '%k\t%T@\t%p\t%p\n' 2>/dev/null
        printf "%s\n" "$targets" | while IFS= read -r target; do
            [ -n "${target:-}" ] || continue
            [ -e "$target" ] || continue
            if have timeout; then
                nice_run timeout 300 find "$target" -xdev -type f -size +"${BIG_FILE_GB}"G \
                    -printf '%k\t%T@\t%p\n' 2>/dev/null
            else
                nice_run find "$target" -xdev -type f -size +"${BIG_FILE_GB}"G \
                    -printf '%k\t%T@\t%p\n' 2>/dev/null
            fi | awk -F'\t' -v t="$target" 'BEGIN {OFS = "\t"} {print $1, $2, $3, t}'
        done
    } | sort -nr > "$UF_BIG"

    # 长期未动的大目录：家目录一级目录 + 数据盘上属于本人的一级条目
    {
        depth_lines "$WORK/home.du" "$user_home" 1 |
            while IFS="$(printf '\t')" read -r kb path; do
                [ -n "${path:-}" ] || continue
                [ "$kb" -ge 10485760 ] || continue      # 只看 ≥10G 的目录
                mtime=$(stat -c '%Y' -- "$path" 2>/dev/null) || continue
                age=$(days_ago "$mtime")
                [ "$age" -ge "$OLD_DAYS" ] || continue
                printf "%s\t%s\t%s\n" "$kb" "$age" "$path"
            done
        awk -F'\t' -v u="$user" '$2 == u && $3 >= 10485760 {print $3 "\t" $5 "\t" $4}' \
            "$WORK/owners.tsv" 2>/dev/null |
            while IFS="$(printf '\t')" read -r kb mtime path; do
                [ -n "${path:-}" ] || continue
                age=$(days_ago "${mtime:-0}")
                [ "$age" -ge "$OLD_DAYS" ] || continue
                printf "%s\t%s\t%s\n" "$kb" "$age" "$path"
            done
    } | sort -nr > "$UF_OLD"

    # 缓存 / 临时目录
    user_cache_candidates | while IFS= read -r rel; do
        kb=$(home_du_lookup "$user_home/$rel")
        [ -n "$kb" ] || continue
        [ "$kb" -ge 1048576 ] || continue               # 小于 1G 的不单独列
        printf "%s\t%s\n" "$kb" "$rel"
    done | sort -nr > "$UF_CACHE"

    USER_CACHE_TOTAL_KB=$(user_cache_roots | while IFS= read -r rel; do
        kb=$(home_du_lookup "$user_home/$rel")
        [ -n "$kb" ] && printf "%s\n" "$kb"
    done | awk '{sum += $1} END {printf "%d\n", sum + 0}')
}

# 一行用量总览：/home 111G + /data 953G + /ssd 1.1T = 2.2T
user_usage_line() { # user_usage_line 用户
    user=$1
    parts="$HOME_ROOT $(human_kb "$USER_HOME_KB")"

    printf "%s\n" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        kb=$(user_data_root_kb "$user" "$root")
        [ "${kb:-0}" -gt 0 ] || continue
        printf " + %s %s" "$root" "$(human_kb "$kb")"
    done > "$WORK/usage.parts"

    printf "%s%s = %s" "$parts" "$(cat "$WORK/usage.parts")" \
        "$(human_kb $((USER_HOME_KB + USER_DATA_KB)))"
}

# 把路径缩短成 ~/xxx，数据盘路径保持原样
short_path() { # short_path 路径 home目录
    case "$1" in
        "$2"/*) printf "~/%s" "${1#"$2"/}" ;;
        "$2") printf "~" ;;
        *) printf "%s" "$1" ;;
    esac
}

# ---------------------------------------------------------------- 精简版（登录展示）

BRIEF_MAX=3

# 路径太长时保留“哪块盘/谁的”和最后两级，中间折叠
brief_path() {
    awk -v p="$1" -v max=62 'BEGIN {
        if (length(p) <= max) { print p; exit }
        n = split(p, c, "/")
        head = (c[1] == "" ? "/" c[2] "/" c[3] : c[1] "/" c[2])   # 绝对路径取前两级，~/ 取前一级
        tail = (n >= 2 ? c[n - 1] "/" c[n] : c[n])
        out = head "/…/" tail
        if (length(out) > max) out = head "/…/" c[n]        # 还长就只留最后一级
        if (length(out) > max) out = "…/" c[n]
        print out
    }'
}

render_global_brief() {
    stamp=$(date '+%m-%d %H:%M')

    if any_root_above_threshold; then
        cecho "$C_BRED" "⚠️  磁盘告警"
    else
        cecho "$C_BLUE" "ℹ️  磁盘情况"
    fi
    cecho "$C_GRAY" "（%s 扫描）\n" "$stamp"

    # 1) 一行磁盘总览
    printf "磁盘："
    first=1
    printf "%s\n" "$ALL_ROOTS" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        info=$(df_info "$root")
        [ -n "$info" ] || continue
        set -- $info
        [ "$first" -eq 1 ] || printf "; "
        first=0
        if [ "$2" -ge "$THRESHOLD" ]; then
            cecho "$C_RED" "%s (已用 %s%%, 剩余 %s/%s)" "$root" "$2" "$(human_kb "$5")" "$(human_kb "$4")"
        else
            cecho "$C_GREEN" "%s (已用 %s%%, 剩余 %s/%s)" "$root" "$2" "$(human_kb "$5")" "$(human_kb "$4")"
        fi
    done
    printf "\n"

    # 2) 一行“各盘占用最多的两个用户”
    printf "占用最多："
    first=1
    printf "%s\n%s\n" "$HOME_ROOT" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ "$root" = "$HOME_ROOT" ]; then
            cells=$(home_top_users)
        else
            cells=$(data_top_users "$root")
        fi
        t1=$(printf "%s" "$cells" | cut -f1)
        t2=$(printf "%s" "$cells" | cut -f2)
        [ "$t1" = "-" ] && t1=
        [ "$t2" = "-" ] && t2=
        [ -n "$t1$t2" ] || continue
        [ "$first" -eq 1 ] || printf "; "
        first=0
        cecho "$C_YELLOW" "%s %s" "$root" "$(printf "%s %s" "$t1" "$t2" | sed 's/ *$//')"
    done
    printf "\n"

    # 3) 一段话：只列需要清理的系统缓存，命令放括号里
    cache_warn_kb=$(gb_to_kb "$CACHE_WARN_GB")
    : > "$WORK/syscache.brief"
    system_cache_candidates | while IFS= read -r path; do
        [ -d "$path" ] && [ -r "$path" ] || continue
        line=$(DU_TIMEOUT=120 du_scan 0 "$path" | head -n 1)
        kb=${line%%	*}
        case "$kb" in ''|*[!0-9]*) continue ;; esac
        [ "$kb" -ge "$cache_warn_kb" ] || continue
        printf "%s %s（%s）\n" "$path" "$(human_kb "$kb")" "$(cache_hint "$path" | sed 's/^[^：]*：//')" \
            >> "$WORK/syscache.brief"
    done
    if [ -s "$WORK/syscache.brief" ]; then
        joined=$(awk 'NR > 1 { printf "；" } { printf "%s", $0 } END { print "" }' "$WORK/syscache.brief")
        cecho "$C_RED" "系统缓存建议清理：%s\n" "$joined"
    fi
}

# 精简版里的一组条目：标红，最多 BRIEF_MAX 条，多的折叠成一句
brief_rows() { # brief_rows 文件 标签 home目录 取列方式
    file=$1
    label=$2
    user_home=$3
    kind=$4

    total=$(wc -l < "$file" 2>/dev/null || echo 0)
    [ "$total" -gt 0 ] || return 0

    head -n "$BRIEF_MAX" "$file" | while IFS="$(printf '\t')" read -r c1 c2 c3 c4; do
        case "$kind" in
            big)
                size=$c1
                note="$(days_ago "${c2%%.*}") 天未动"
                path=$c3
                [ "${c4:-1}" -gt 1 ] && note="${c4} 个文件，$note"
                ;;
            old)   size=$c1; note="$c2 天未动"; path=$c3 ;;
            cache) size=$c1; note=; path="$user_home/$c2" ;;
        esac
        shown_path=$(brief_path "$(short_path "$path" "$user_home")")
        if [ -n "$note" ]; then
            cecho "$C_RED" "  %s %s  %s（%s）\n" "$(pad "$label" 10)" \
                "$(rpad "$(human_kb "$size")" 7)" "$shown_path" "$note"
        else
            cecho "$C_RED" "  %s %s  %s\n" "$(pad "$label" 10)" \
                "$(rpad "$(human_kb "$size")" 7)" "$shown_path"
        fi
    done

    if [ "$total" -gt "$BRIEF_MAX" ]; then
        cecho "$C_GRAY" "  %s 另有 %s 项，见完整报告\n" "$(pad "" 10)" "$((total - BRIEF_MAX))"
    fi
}

render_user_brief() { # render_user_brief 用户 home目录
    user=$1
    user_home=$2

    printf "\n"
    cecho "$C_BYELLOW" "🙋 你的用量："
    printf "%s\n" "$(user_usage_line "$user")"

    if [ -s "$UF_BIG" ] || [ -s "$UF_OLD" ] || [ -s "$UF_CACHE" ]; then
        cecho "$C_BYELLOW" "需要处理：\n"
        # 同一个一级目录下的多个大文件合并成一行（模型目录往往是几十个分片文件）
        awk -F'\t' '
            {
                d = $3
                sub(/\/[^\/]*$/, "", d)          # 文件所在目录
                if (d == "") d = "/"
                kb[d] += $1
                n[d] += 1
                t = int($2)                       # 注意要取整，否则 print 会变成科学计数法
                if (t > newest[d]) newest[d] = t
                if ($1 + 0 > maxkb[d]) { maxkb[d] = $1 + 0; maxpath[d] = $3 }
            }
            END {
                for (d in kb) printf "%d\t%d\t%s\t%d\n", kb[d], newest[d], (n[d] > 1 ? d : maxpath[d]), n[d]
            }' "$UF_BIG" | sort -nr > "$WORK/uf.big.brief"
        brief_rows "$WORK/uf.big.brief" "大文件" "$user_home" big
        brief_rows "$UF_OLD" "长期未动" "$user_home" old
        awk -F'\t' '{
            keep = 1
            for (i = 1; i <= n; i++) if (index($2, kept[i] "/") == 1) { keep = 0; break }
            if (keep) { kept[++n] = $2; print }
        }' "$UF_CACHE" > "$WORK/uf.cache.brief"
        brief_rows "$WORK/uf.cache.brief" "缓存临时" "$user_home" cache
    fi

    cecho "$C_BYELLOW" "清理建议：\n"
    print_user_advice "$user" "$user_home"
}

# ---------------------------------------------------------------- 完整版（--report / --self / --test）

print_user_disk_usage() { # print_user_disk_usage 用户 home目录
    user=$1
    user_home=$2

    cecho "$C_BLUE" "📦 你的用量分布\n"
    cecho "$C_BLUE" "%s\n" "$(trow 26 "位置" r8 "占用" "说明")"
    cecho "$C_GRAY" "%s\n" "$(tsep 26 8 34)"

    home_total=$(df_info "$HOME_ROOT" | awk '{print $4}')
    home_share=$(awk -v a="$USER_HOME_KB" -v b="${home_total:-0}" -v root="$HOME_ROOT" \
        'BEGIN { if (b > 0) printf "占 %s 的 %.1f%%\n", root, a * 100 / b; else print "-" }')
    cecho "$C_CYAN" "%s\n" "$(trow 26 "$user_home" r8 "$(human_kb "$USER_HOME_KB")" "$home_share")"

    printf "%s\n" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        kb=$(user_data_root_kb "$user" "$root")
        [ "${kb:-0}" -gt 0 ] || continue
        entries=$(awk -F'\t' -v u="$user" -v r="$root" '$1 == r && $2 == u {n++} END {print n + 0}' "$WORK/owners.tsv")
        cecho "$C_CYAN" "%s\n" "$(trow 26 "$root（属于你的目录）" r8 "$(human_kb "$kb")" "共 $entries 个一级条目")"
    done

    cecho "$C_BLUE" "%s\n" "$(trow 26 "合计" r8 "$(human_kb $((USER_HOME_KB + USER_DATA_KB)))" \
        "提示阈值：/home ${USER_HOME_WARN_GB}G，数据盘 ${USER_DATA_WARN_GB}G")"
}

print_user_top_entries() { # print_user_top_entries 用户 home目录
    user=$1
    user_home=$2

    cecho "$C_BYELLOW" "📁 家目录下较大的一级目录与文件（Top 8）\n"
    cecho "$C_BYELLOW" "%s\n" "$(trow 32 "名称" r8 "占用" r10 "最近改动" "说明")"
    cecho "$C_GRAY" "%s\n" "$(tsep 32 8 10 28)"

    {
        depth_lines "$WORK/home.du" "$user_home" 1
        first_level_files "$user_home"
    } | sort -nr | head -n 8 | while IFS="$(printf '\t')" read -r kb path; do
        [ -n "${path:-}" ] || continue
        mtime=$(stat -c '%Y' -- "$path" 2>/dev/null)
        age=$(days_ago "${mtime:-0}")
        name=$(truncate_text "$(basename "$path")" 31)
        if [ "$age" -ge "$OLD_DAYS" ]; then
            cecho "$C_RED" "%s\n" "$(trow 32 "$name" r8 "$(human_kb "$kb")" r10 "${age} 天前" \
                "⚠ 超过 ${OLD_DAYS} 天未改动，优先确认")"
        else
            cecho "$C_YELLOW" "%s\n" "$(trow 32 "$name" r8 "$(human_kb "$kb")" r10 "${age} 天前" "")"
        fi
    done

    printf "%s\n" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        rows=$(awk -F'\t' -v u="$user" -v r="$root" 'BEGIN {OFS="\t"} $1 == r && $2 == u {print $3, $4, $5}' \
            "$WORK/owners.tsv" | sort -nr | head -n 5)
        [ -n "$rows" ] || continue
        printf "\n"
        cecho "$C_BCYAN" "📁 %s 下属于你的一级目录（Top 5）\n" "$root"
        cecho "$C_BCYAN" "%s\n" "$(trow 32 "名称" r8 "占用" r10 "最近改动" "最大子目录")"
        cecho "$C_GRAY" "%s\n" "$(tsep 32 8 10 28)"
        printf "%s\n" "$rows" | while IFS="$(printf '\t')" read -r kb path mtime; do
            [ -n "${path:-}" ] || continue
            age=$(days_ago "${mtime:-0}")
            cache=$(root_cache "$root")
            child=$(depth_lines "$cache" "$path" 1 | sort -nr | head -n 1 |
                while IFS="$(printf '\t')" read -r ckb cpath; do
                    [ -n "${cpath:-}" ] || continue
                    printf "%s (%s)" "$(truncate_text "$(basename "$cpath")" 22)" "$(human_kb "$ckb")"
                done)
            name=$(truncate_text "$(basename "$path")" 31)
            if [ "$age" -ge "$OLD_DAYS" ]; then
                cecho "$C_RED" "%s\n" "$(trow 32 "$name" r8 "$(human_kb "$kb")" r10 "${age} 天前" "${child:--}")"
            else
                cecho "$C_CYAN" "%s\n" "$(trow 32 "$name" r8 "$(human_kb "$kb")" r10 "${age} 天前" "${child:--}")"
            fi
        done
    done
}

print_user_big_files() {
    cecho "$C_BYELLOW" "🗂  大文件（单个 > %sG）\n" "$BIG_FILE_GB"
    if [ ! -s "$UF_BIG" ]; then
        cecho "$C_GRAY" "    没有超过 %sG 的单个文件\n" "$BIG_FILE_GB"
        return
    fi
    cecho "$C_BYELLOW" "%s\n" "$(trow r8 "大小" r10 "最近改动" "路径")"
    cecho "$C_GRAY" "%s\n" "$(tsep 8 10 48)"
    while IFS="$(printf '\t')" read -r kb mtime path target; do
        [ -n "${path:-}" ] || continue
        age=$(days_ago "${mtime%%.*}")
        if [ "$age" -ge "$OLD_DAYS" ]; then
            cecho "$C_RED" "%s\n" "$(trow r8 "$(human_kb "$kb")" r10 "${age} 天前" "$path")"
        else
            cecho "$C_YELLOW" "%s\n" "$(trow r8 "$(human_kb "$kb")" r10 "${age} 天前" "$path")"
        fi
    done < "$UF_BIG"
}

print_user_cache() {
    user_home=$1

    cecho "$C_BCYAN" "🧰 缓存 / 临时文件（合计约 %s）\n" "$(human_kb "$USER_CACHE_TOTAL_KB")"
    if [ ! -s "$UF_CACHE" ]; then
        cecho "$C_GRAY" "    没有超过 1G 的缓存目录\n"
        return
    fi
    cecho "$C_BCYAN" "%s\n" "$(trow 28 "目录" r8 "占用" "清理方式")"
    cecho "$C_GRAY" "%s\n" "$(tsep 28 8 38)"
    while IFS="$(printf '\t')" read -r kb rel; do
        [ -n "${rel:-}" ] || continue
        cecho "$C_CYAN" "%s\n" "$(trow 28 "~/$rel" r8 "$(human_kb "$kb")" "$(cache_clean_hint "$rel")")"
    done < "$UF_CACHE"
}

# 清理建议：一条一条，围绕缓存临时文件和大文件
print_user_advice() { # print_user_advice 用户 home目录
    user=$1
    user_home=$2
    first_data=$(printf "%s\n" "$DATA_ROOT_LIST" | head -n 1)
    n=0

    # 1) 缓存：按实际存在的缓存目录给命令
    if [ -s "$UF_CACHE" ]; then
        cmds=$(cut -f2 "$UF_CACHE" | while IFS= read -r rel; do
            cache_clean_hint "$rel" | sed 's/^删除/删/'
        done | awk 'NF && !seen[$0]++' | head -n 3 |
            awk 'NR > 1 { printf "；" } { printf "%s", $0 } END { print "" }')
        n=$((n + 1))
        cecho "$C_RED" "  %s. 缓存共 %s：%s\n" "$n" "$(human_kb "$USER_CACHE_TOTAL_KB")" "$cmds"
    fi

    # 2) 大文件：给出最大的几个，直接可删/可归档
    if [ -s "$UF_BIG" ]; then
        big_n=$(wc -l < "$UF_BIG")
        big_kb=$(awk -F'\t' '{sum += $1} END {printf "%d\n", sum + 0}' "$UF_BIG")
        top_path=$(head -n 1 "$UF_BIG" | cut -f3)   # 第 3 列始终是单个文件的真实路径
        n=$((n + 1))
        cecho "$C_RED" "  %s. %s 个大文件共 %s，最大的是 %s；checkpoint 只留最优与最后一个，数据集压缩包解压后删掉\n" \
            "$n" "$big_n" "$(human_kb "$big_kb")" "$(brief_path "$(short_path "$top_path" "$user_home")")"
    fi

    # 3) 长期未动
    if [ -s "$UF_OLD" ]; then
        old_list=$(head -n 3 "$UF_OLD" | while IFS="$(printf '\t')" read -r kb age path; do
            printf "%s(%s, %s天) " "$(basename "$path")" "$(human_kb "$kb")" "$age"
        done)
        n=$((n + 1))
        cecho "$C_RED" "  %s. 超过 %s 天没动过：%s确认后归档或删除\n" "$n" "$OLD_DAYS" "$old_list"
    fi

    # 4) /home 紧张时提示迁到数据盘
    if [ "$USER_HOME_KB" -ge "$(gb_to_kb "$USER_HOME_WARN_GB")" ] && [ -n "$first_data" ]; then
        n=$((n + 1))
        cecho "$C_RED" "  %s. /home 在系统盘上最紧张，把数据集/模型/输出迁到 %s/%s 并做软链接（mv ~/big_dir %s/%s/ && ln -s %s/%s/big_dir ~/big_dir）\n" \
            "$n" "$first_data" "$user" "$first_data" "$user" "$first_data" "$user"
    fi

    if [ "$n" -eq 0 ]; then
        cecho "$C_GRAY" "  暂时没有明显可清理的内容\n"
    fi
}

render_user() { # render_user 用户 home目录（完整版）
    user=$1
    user_home=$2
    stamp=$(date '+%Y-%m-%d %H:%M:%S')

    cecho "$C_BYELLOW" "%s\n" "==============================================================="
    cecho "$C_BYELLOW" "🙋 %s 的用量分析与清理建议\n" "$user"
    cecho "$C_GRAY" "    扫描时间：%s\n" "$stamp"
    cecho "$C_BYELLOW" "%s\n" "==============================================================="
    printf "\n"
    print_user_disk_usage "$user" "$user_home"
    printf "\n"
    print_user_top_entries "$user" "$user_home"
    printf "\n"
    print_user_big_files
    printf "\n"
    print_user_cache "$user_home"
    printf "\n"
    cecho "$C_BRED" "💡 清理建议\n"
    print_user_advice "$user" "$user_home"
}

user_over_threshold() { # user_over_threshold 用户 home目录
    user=$1
    user_home=$2

    [ "$FORCE" -eq 1 ] && return 0

    home_kb=$(home_du_lookup "$user_home")
    data_kb=$(user_data_total_kb "$user")
    [ "${home_kb:-0}" -ge "$(gb_to_kb "$USER_HOME_WARN_GB")" ] && return 0
    [ "${data_kb:-0}" -ge "$(gb_to_kb "$USER_DATA_WARN_GB")" ] && return 0
    return 1
}

# ---------------------------------------------------------------- 展示 / 入口

display_file() {
    [ -r "$1" ] || return 0
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        cat -- "$1"
    else
        sed "s/$(printf '\033')\[[0-9;]*m//g" -- "$1"
    fi
}

# 报告超过 2 天未刷新时提示定时器可能没在跑
warn_if_stale() { # warn_if_stale 文件
    mtime=$(stat -c '%Y' -- "$1" 2>/dev/null) || return 0
    age=$(days_ago "$mtime")
    [ "$age" -ge 2 ] || return 0
    cecho "$C_GRAY" "    注意：报告已是 %s 天前生成，请检查 systemctl status disk_usage_warn.timer\n" "$age"
}

run_login() {
    report="$USER_REPORT_DIR/$(id -un)"
    brief="$report.brief"

    # 盘超阈值，或本人有个人报告（即个人用量超阈值），都显示两部分
    if ! any_root_above_threshold && [ ! -r "$brief" ]; then
        return 0
    fi

    shown=0
    if [ -r "$GLOBAL_BRIEF" ]; then
        display_file "$GLOBAL_BRIEF"
        shown=1
    fi
    if [ -r "$brief" ]; then
        display_file "$brief"
        shown=1
    fi
    [ "$shown" -eq 1 ] || return 0

    [ -r "$GLOBAL_BRIEF" ] && warn_if_stale "$GLOBAL_BRIEF"
    cecho "$C_GRAY" "完整报告：%s --report\n" "$0"
}

# 打印本次扫描的完整报告（不重新扫描）
run_report() {
    report="$USER_REPORT_DIR/$(id -un)"
    shown=0

    if [ -r "$GLOBAL_REPORT" ]; then
        display_file "$GLOBAL_REPORT"
        shown=1
    fi
    if [ -r "$report" ]; then
        [ "$shown" -eq 1 ] && printf "\n"
        display_file "$report"
        shown=1
    fi

    if [ "$shown" -eq 0 ]; then
        printf "还没有扫描结果。现在自查：%s --self；管理员可执行 sudo %s --scan\n" "$0" "$0"
        return 1
    fi
    warn_if_stale "$GLOBAL_REPORT"
}

write_atomic() { # write_atomic 目标文件 [属主]
    target=$1
    owner=${2:-}
    tmp="$target.$$"

    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -n "$owner" ]; then
        chown "$owner" "$tmp" 2>/dev/null && chmod 0600 "$tmp" || chmod 0644 "$tmp"
    else
        chmod 0644 "$tmp"
    fi
    mv -f "$tmp" "$target"
}

run_scan() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "警告：非 root 运行，其他用户目录将无法统计\n" >&2
    fi

    mkdir -p "$STATE_DIR" "$USER_REPORT_DIR" || exit 1
    chmod 0755 "$STATE_DIR" "$USER_REPORT_DIR"

    pstage 1 3 "扫描磁盘：$(printf "%s" "$ALL_ROOTS" | tr '\n' ' ')"
    build_caches

    pstage 2 3 "生成全局报告"
    # 全局报告始终生成：个人用量超标的用户登录时也要看到全局情况
    render_global | write_atomic "$GLOBAL_REPORT"
    render_global_brief | write_atomic "$GLOBAL_BRIEF"

    # 有盘超阈值时，所有用户都要看到自己的用量分析；否则只给超标用户生成
    global_hit=0
    any_root_above_threshold && global_hit=1

    user_total=$(list_home_user_dirs | wc -l)
    pstage 3 3 "生成用户报告（$user_total 个用户，只对大目录做大文件扫描）"

    user_i=0
    list_home_user_dirs | while IFS= read -r user_home; do
        user=$(basename "$user_home")
        user_i=$((user_i + 1))
        report="$USER_REPORT_DIR/$user"
        pline "$(pbar "$user_i" "$user_total" 24 | tr -d '\n')  ${user_i}/${user_total}  $user  $(elapsed_text)"
        if [ "$global_hit" -eq 1 ] || user_over_threshold "$user" "$user_home"; then
            collect_user_facts "$user" "$user_home"
            render_user "$user" "$user_home" | write_atomic "$report" "$user"
            render_user_brief "$user" "$user_home" | write_atomic "$report.brief" "$user"
        else
            rm -f "$report" "$report.brief"
        fi
    done
    pdone "用户报告完成，总用时 $(elapsed_text)"
}

# 只扫描当前用户，供普通用户随时自查
build_self_caches() {
    init_work
    user=$(id -un)
    user_home=${HOME:-$HOME_ROOT/$user}

    du_scan 4 "$user_home" > "$WORK/home.du"
    df_info "$HOME_ROOT" >/dev/null

    : > "$WORK/owners.tsv"
    printf "%s\n" "$DATA_ROOT_LIST" | while IFS= read -r root; do
        [ -n "$root" ] || continue
        cache=$(data_root_cache "$root")
        : > "$cache"
        find "$root"/ -maxdepth 1 -xdev -user "$user" 2>/dev/null | while IFS= read -r path; do
            [ "$path" = "$root/" ] && continue
            du_scan 1 "$path" >> "$cache"
            kb=$(awk -F'\t' -v p="$path" '$2 == p {print $1; exit}' "$cache")
            [ -n "$kb" ] || continue
            mtime=$(stat -c '%Y' -- "$path" 2>/dev/null)
            printf "%s\t%s\t%s\t%s\t%s\n" "$root" "$user" "$kb" "$path" "${mtime:-0}" >> "$WORK/owners.tsv"
        done
    done
}

run_self() {
    pstage 1 2 "扫描 $(id -un) 的家目录与数据目录"
    build_self_caches
    pstage 2 2 "分析并生成建议"
    user=$(id -un)
    user_home=${HOME:-$HOME_ROOT/$user}
    if any_root_above_threshold || user_over_threshold "$user" "$user_home"; then
        collect_user_facts "$user" "$user_home"
        render_user "$user" "$user_home"
    else
        printf "磁盘都在 %s%% 以下，个人用量也未超过阈值（/home %sG / 数据盘 %sG），无需清理。加 --force 可强制输出。\n" \
            "$THRESHOLD" "$USER_HOME_WARN_GB" "$USER_DATA_WARN_GB"
    fi
}

run_test() {
    build_caches

    user=$(id -un)
    user_home=${HOME:-$HOME_ROOT/$user}
    case "$user_home" in
        "$HOME_ROOT"/*) ;;
        *)
            # root 等家目录不在 /home 下的账号，改用占用最大的用户做样例
            top=$(depth_lines "$WORK/home.du" "$HOME_ROOT" 1 | sort -nr | head -n 1 | cut -f2)
            if [ -n "$top" ]; then
                cecho "$C_GRAY" "（%s 的家目录不在 %s 下，下面用占用最大的用户 %s 作为预览）\n\n" \
                    "$user" "$HOME_ROOT" "$(basename "$top")"
                user=$(basename "$top")
                user_home=$top
            fi
            ;;
    esac
    # 先按登录时看到的样子预览，再给完整报告
    collect_user_facts "$user" "$user_home"
    render_global_brief
    render_user_brief "$user" "$user_home"
    cecho "$C_GRAY" "完整报告：%s --report\n" "$0"
    printf "\n"
    rule
    printf "\n"
    render_global
    printf "\n"
    render_user "$user" "$user_home"
}

case "$MODE" in
    login) run_login ;;
    roots) print_roots ;;
    report) run_report ;;
    scan) run_scan ;;
    self) run_self ;;
    test) run_test ;;
esac
