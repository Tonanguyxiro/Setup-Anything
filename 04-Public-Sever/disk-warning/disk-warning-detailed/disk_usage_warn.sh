#!/bin/sh
# SSH登录警告：/home或数据目录磁盘使用率超过90%提醒

# 告警阈值（可自行修改，比如95、98）
THRESHOLD=90

HOME_ROOT=/home
TEST_MODE=${TEST_MODE:-0}
SCAN_MODE=0
DATA_ROOT_NAMES=${DATA_ROOT_NAMES:-"data data1 data2 ssd ssd1 nvme scratch shared"}
LOG_FILE=${LOG_FILE:-/var/log/disk_usage_warn.log}

if [ "$1" = "--test" ] || [ "$1" = "test" ]; then
    TEST_MODE=1
fi

if [ "$1" = "--scan" ] || [ "$1" = "--update-log" ]; then
    SCAN_MODE=1
fi

# 核心：获取/home目录的磁盘使用率（纯数字，去掉%）
DISK_USAGE=$(df -h /home | tail -n 1 | awk '{print $5}' | tr -d '%')

du_one_level_dirs() {
    root_dir="$1"

    find "$root_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        while IFS= read -r path; do
            du_path_human "$path"
        done
}

du_path_human() {
    path="$1"

    if [ "$USE_SUDO" -eq 1 ]; then
        sudo -n du -xsh "$path" 2>/dev/null
    else
        du -xsh "$path" 2>/dev/null
    fi
}

du_path_kb() {
    path="$1"

    if [ "$USE_SUDO" -eq 1 ]; then
        sudo -n du -xs "$path" 2>/dev/null
    else
        du -xs "$path" 2>/dev/null
    fi
}

path_usage_percent() {
    path="$1"

    df -P "$path" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}'
}

format_kb() {
    kb="$1"

    if command -v numfmt >/dev/null 2>&1; then
        numfmt --from-unit=1024 --to=iec --suffix=B "$kb"
    else
        printf "%sK" "$kb"
    fi
}

truncate_text() {
    text="$1"
    max_len="$2"

    awk -v text="$text" -v max_len="$max_len" '
        BEGIN {
            if (length(text) > max_len) {
                print substr(text, 1, max_len - 3) "..."
            } else {
                print text
            }
        }
    '
}

top_cell_from_du_line() {
    line="$1"

    [ -n "$line" ] || {
        printf "-"
        return
    }

    set -- $line
    size=$1
    path=$2
    name=$(basename "$path")
    name=$(truncate_text "$name" 16)
    printf "%s %s" "$size" "$name"
}

print_ranked_row() {
    rank="$1"
    color="$2"
    shift 2

    if [ -n "$color" ]; then
        printf "%b" "$color"
    fi
    printf "$@"
    if [ -n "$color" ]; then
        printf "%b" "\033[0m"
    fi
}

print_section_break() {
    printf "\n\033[90m---------------------------------------------------------------\033[0m\n\n"
}

is_data_root_name() {
    name="$1"

    for data_name in $DATA_ROOT_NAMES; do
        if [ "$name" = "$data_name" ]; then
            return 0
        fi
    done

    return 1
}

list_home_user_dirs() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd | awk -F: -v root="$HOME_ROOT" '$6 ~ "^" root "/[^/]+$" {print $6}' | sort -u |
            while IFS= read -r user_home; do
                user_name=$(basename "$user_home")
                if [ -d "$user_home" ] && [ ! -L "$user_home" ] && ! is_data_root_name "$user_name"; then
                    printf "%s\n" "$user_home"
                fi
            done
    else
        find "$HOME_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
            while IFS= read -r user_home; do
                user_name=$(basename "$user_home")
                if ! is_data_root_name "$user_name"; then
                    printf "%s\n" "$user_home"
                fi
            done
    fi
}

list_one_level_entries() {
    root_dir="$1"

    find "$root_dir"/ -mindepth 1 -maxdepth 1 ! -type l 2>/dev/null
}

list_data_roots() {
    for data_name in $DATA_ROOT_NAMES; do
        if [ -d "/$data_name" ]; then
            printf "%s\n" "/$data_name"
        fi
    done
}

any_data_root_above_threshold() {
    for data_name in $DATA_ROOT_NAMES; do
        if [ -d "/$data_name" ]; then
            usage=$(path_usage_percent "/$data_name")
        else
            usage=
        fi

        if [ -n "$usage" ] && [ "$usage" -gt "$THRESHOLD" ]; then
            return 0
        fi
    done

    return 1
}

if [ "$SCAN_MODE" -eq 0 ] && [ "$TEST_MODE" -eq 0 ]; then
    if [ -r "$LOG_FILE" ] && { [ "$DISK_USAGE" -gt "$THRESHOLD" ] || any_data_root_above_threshold; }; then
        cat "$LOG_FILE"
    fi
    return 0 2>/dev/null || exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    USE_SUDO=0
elif sudo -n true 2>/dev/null; then
    USE_SUDO=1
else
    USE_SUDO=0
fi

print_usage_summary() {
    printf "\n\033[1;34m📊 磁盘使用情况\033[0m\n"
    printf "\033[1;34m%-12s %-8s %-18s\033[0m\n" "挂载点" "使用率" "状态"

    if [ "$DISK_USAGE" -gt "$THRESHOLD" ]; then
        printf "\033[31m%-12s %-8s %-18s\033[0m\n" "/home" "${DISK_USAGE}%" "已超过 ${THRESHOLD}%"
    else
        printf "\033[32m%-12s %-8s %-18s\033[0m\n" "/home" "${DISK_USAGE}%" "正常"
    fi

    list_data_roots |
        while IFS= read -r data_root; do
            usage=$(path_usage_percent "$data_root")
            if [ -n "$usage" ]; then
                if [ "$usage" -gt "$THRESHOLD" ]; then
                    printf "\033[31m%-12s %-8s %-18s\033[0m\n" "$data_root" "${usage}%" "已超过 ${THRESHOLD}%"
                else
                    printf "\033[32m%-12s %-8s %-18s\033[0m\n" "$data_root" "${usage}%" "正常"
                fi
            fi
        done
}

print_largest_home_users() {
    printf "\033[1;33m🏠 /home 占用较大的用户\033[0m\n"
    printf "\033[1;33m%-6s %-12s %-8s %-22s %-22s %-22s\033[0m\n" "排名" "用户" "总占用" "Top1" "Top2" "Top3"
    list_home_user_dirs |
        while IFS= read -r user_home; do
            du_path_human "$user_home"
        done |
        sort -hr | head -n 5 |
        while IFS= read -r line; do
            user_rank=$((user_rank + 1))
            set -- $line
            size=$1
            user_home=$2
            user_name=$(basename "$user_home")
            top_lines=$(du_one_level_dirs "$user_home" | sort -hr | head -n 3)
            top1=$(top_cell_from_du_line "$(printf "%s\n" "$top_lines" | sed -n '1p')")
            top2=$(top_cell_from_du_line "$(printf "%s\n" "$top_lines" | sed -n '2p')")
            top3=$(top_cell_from_du_line "$(printf "%s\n" "$top_lines" | sed -n '3p')")
            user_name=$(truncate_text "$user_name" 12)

            if [ "$user_rank" -eq 1 ]; then
                print_ranked_row "$user_rank" "\033[1;33m" "%-6s %-12s %-8s %-22s %-22s %-22s\n" "#1" "$user_name" "$size" "$top1" "$top2" "$top3"
            elif [ "$user_rank" -eq 2 ]; then
                print_ranked_row "$user_rank" "\033[1;35m" "%-6s %-12s %-8s %-22s %-22s %-22s\n" "#2" "$user_name" "$size" "$top1" "$top2" "$top3"
            else
                printf "\033[33m%-6s %-12s %-8s %-22s %-22s %-22s\033[0m\n" "#$user_rank" "$user_name" "$size" "$top1" "$top2" "$top3"
            fi
        done
}

print_data_root_report() {
    data_root="$1"

    printf "\n\033[1;36m💽 数据盘：%s\033[0m\n" "$data_root"
    printf "\033[1;36m%-6s %-8s %-36s %-12s\033[0m\n" "排名" "大小" "名称" "owner"
    list_one_level_entries "$data_root" |
        while IFS= read -r path; do
            du_line=$(du_path_human "$path")
            set -- $du_line
            size=$1
            owner=$(stat -c "%U" "$path" 2>/dev/null)
            entry_name=$(basename "$path")
            if [ -n "$size" ]; then
                printf "%s %s %s\n" "$size" "$owner" "$entry_name"
            fi
        done |
        sort -hr | head -n 5 |
        while IFS= read -r line; do
            entry_rank=$((entry_rank + 1))
            set -- $line
            size=$1
            owner=$2
            entry_name=$3
            entry_name=$(truncate_text "$entry_name" 36)
            owner=$(truncate_text "$owner" 12)
            if [ "$entry_rank" -eq 1 ]; then
                print_ranked_row "$entry_rank" "\033[1;33m" "%-6s %-8s %-36s %-12s\n" "#1" "$size" "$entry_name" "$owner"
            elif [ "$entry_rank" -eq 2 ]; then
                print_ranked_row "$entry_rank" "\033[1;35m" "%-6s %-8s %-36s %-12s\n" "#2" "$size" "$entry_name" "$owner"
            else
                printf "\033[36m%-6s %-8s %-36s %-12s\033[0m\n" "#$entry_rank" "$size" "$entry_name" "$owner"
            fi
        done
}

print_data_root_owner_usage() {
    data_root="$1"

    list_one_level_entries "$data_root" |
        while IFS= read -r path; do
            du_line=$(du_path_kb "$path")
            set -- $du_line
            kb=$1
            owner=$(stat -c "%U" "$path" 2>/dev/null)
            if [ -n "$kb" ] && [ -n "$owner" ]; then
                printf "%s %s %s\n" "$kb" "$owner" "$data_root"
            fi
        done
}

print_data_roots_report() {
    data_roots=$(list_data_roots)

    if [ -z "$data_roots" ]; then
        printf "\033[36m💽 未发现数据盘候选目录：%s\033[0m\n" "$DATA_ROOT_NAMES"
        return
    fi

    printf "\033[1;36m📦 请检查数据盘中以下大文件是否过时：\033[0m\n"
    printf "%s\n" "$data_roots" |
        while IFS= read -r data_root; do
            print_data_root_report "$data_root"
        done
}

print_data_owner_report() {
    data_roots=$(list_data_roots)
    data_headers=$(printf "%s\n" "$data_roots" | awk '{printf " %-10s", $1}')

    if [ -z "$data_roots" ]; then
        return
    fi

    printf "\033[1;36m👤 数据盘用户总占用\033[0m\n"
    printf "\033[1;36m%-6s %-12s %-8s%s\033[0m\n" "排名" "用户" "总占用" "$data_headers"
    printf "%s\n" "$data_roots" |
        while IFS= read -r data_root; do
            print_data_root_owner_usage "$data_root"
        done |
        awk '
            function human(kb) {
                if (kb >= 1073741824) return sprintf("%.1fT", kb / 1073741824)
                if (kb >= 1048576) return sprintf("%.1fG", kb / 1048576)
                if (kb >= 1024) return sprintf("%.1fM", kb / 1024)
                return kb "K"
            }
            {
                per[$2 "\t" $3] += $1
                total[$2] += $1
            }
            END {
                for (owner in total) {
                    for (key in per) {
                        split(key, parts, "\t")
                        if (parts[1] == owner) {
                            print total[owner], owner, parts[2], per[key]
                        }
                    }
                }
            }
        ' |
        sort -nr |
        awk -v roots="$data_roots" '
            function human(kb) {
                if (kb >= 1073741824) return sprintf("%.1fT", kb / 1073741824)
                if (kb >= 1048576) return sprintf("%.1fG", kb / 1048576)
                if (kb >= 1024) return sprintf("%.1fM", kb / 1024)
                return kb "K"
            }
            function trunc(text, max_len) {
                if (length(text) > max_len) return substr(text, 1, max_len - 3) "..."
                return text
            }
            BEGIN {
                root_count = split(roots, root_list, "\n")
            }
            owner_seen[$2] == 0 {
                owner_seen[$2] = 1
                owner_count += 1
                if (owner_count > 5) exit
                rank = "#" owner_count
                owner_order[owner_count] = $2
                owner_total[$2] = $1
            }
            owner_count <= 5 {
                owner_disk[$2 "\t" $3] = $4
            }
            END {
                for (i = 1; i <= owner_count && i <= 5; i++) {
                    owner = owner_order[i]
                    color = "\033[36m"
                    if (i == 1) color = "\033[1;33m"
                    if (i == 2) color = "\033[1;35m"
                    printf "%s%-6s %-12s %-8s", color, "#" i, trunc(owner, 12), human(owner_total[owner])
                    for (r = 1; r <= root_count; r++) {
                        key = owner "\t" root_list[r]
                        value = owner_disk[key] ? human(owner_disk[key]) : "-"
                        printf " %-10s", value
                    }
                    printf "\033[0m\n"
                }
            }
        '
}

should_warn() {
    [ "$DISK_USAGE" -gt "$THRESHOLD" ] || any_data_root_above_threshold || [ "$TEST_MODE" -eq 1 ]
}

render_report() {
    printf "\033[31m===============================================================\033[0m\n"
    if [ "$TEST_MODE" -eq 1 ] && [ "$DISK_USAGE" -le "$THRESHOLD" ] && ! any_data_root_above_threshold; then
        printf "\033[31m🧪 测试模式：强制输出 /home 和数据盘占用排行\033[0m\n"
    else
        printf "\033[31m⚠️  系统警告：磁盘空间超过告警阈值！\033[0m\n"
    fi
    print_usage_summary
    printf "\n\033[31m💡 请及时清理过时文件，避免服务异常！\033[0m\n"
    print_section_break
    print_largest_home_users
    print_section_break
    print_data_roots_report
    print_section_break
    print_data_owner_report
    printf "\033[31m===============================================================\033[0m\n"
}

write_log() {
    tmp_file="${LOG_FILE}.$$"

    render_report > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 0644 "$tmp_file"
    mv "$tmp_file" "$LOG_FILE"
}

if [ "$SCAN_MODE" -eq 1 ]; then
    if should_warn; then
        write_log
    else
        rm -f "$LOG_FILE"
    fi
    scan_status=$?
    return "$scan_status" 2>/dev/null || exit "$scan_status"
fi

# 测试模式直接输出实时扫描结果。
if should_warn; then
    render_report
fi
