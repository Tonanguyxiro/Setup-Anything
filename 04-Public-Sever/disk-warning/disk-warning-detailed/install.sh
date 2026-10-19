#!/bin/sh
# 安装 / 更新 / 卸载磁盘用量告警（需要 root）
#
#   sudo ./install.sh              安装：脚本 + 登录钩子 + systemd timer，并立即扫描一次
#   sudo ./install.sh --update     更新脚本与 systemd 单元（保留配置），并重新扫描
#   sudo ./install.sh --remove     卸载（保留 /etc/disk-usage-warn.conf）
#   sudo ./install.sh --remove --purge
#                                  卸载并删除配置与缓存
#   sudo ./install.sh --status     查看定时器状态与缓存文件
#
# 可用环境变量：NO_SCAN=1 安装后不立即扫描（首次扫描较慢时使用）

set -eu

BIN_PATH=/usr/local/sbin/disk_usage_warn.sh
PROFILE_PATH=/etc/profile.d/disk_usage_warn.sh
CONFIG_PATH=/etc/disk-usage-warn.conf
UNIT_DIR=/etc/systemd/system
STATE_DIR=/var/lib/disk-usage-warn
SERVICE=disk_usage_warn.service
TIMER=disk_usage_warn.timer

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ACTION=install
ACTION_FLAG=
PURGE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --update) ACTION=update; ACTION_FLAG=--update ;;
        --remove|--uninstall) ACTION=remove; ACTION_FLAG=--remove ;;
        --status) ACTION=status; ACTION_FLAG=--status ;;
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
    esac
    shift
done

need_root() {
    [ "$(id -u)" -eq 0 ] || {
        echo "请用 root 运行：sudo $0${ACTION_FLAG:+ $ACTION_FLAG}" >&2
        exit 1
    }
}

have_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

install_files() {
    install -m 0755 "$SRC_DIR/disk_usage_warn.sh" "$BIN_PATH"
    install -m 0644 "$SRC_DIR/disk_usage_warn_profile.sh" "$PROFILE_PATH"
    install -d -m 0755 "$STATE_DIR" "$STATE_DIR/users"
    echo "已安装：$BIN_PATH"
    echo "已安装：$PROFILE_PATH"

    # 清理旧版本：之前把整个脚本放在 profile.d，并写 /var/log/disk_usage_warn.log
    if [ -f /var/log/disk_usage_warn.log ]; then
        rm -f /var/log/disk_usage_warn.log
        echo "已清理旧版缓存：/var/log/disk_usage_warn.log"
    fi
}

write_config() {
    [ -f "$CONFIG_PATH" ] && {
        echo "保留已有配置：$CONFIG_PATH"
        return 0
    }
    cat > "$CONFIG_PATH" <<'CONF'
# 磁盘用量告警配置（/usr/local/sbin/disk_usage_warn.sh 启动时读取）

# 磁盘使用率告警阈值（%）：任一盘超过即在登录时显示全局信息
THRESHOLD=90

# 用户级提示阈值
USER_HOME_WARN_GB=100    # 家目录超过多少 GiB 时提示该用户
USER_DATA_WARN_GB=500    # 数据盘合计超过多少 GiB 时提示该用户

# 系统缓存目录超过多少 GiB 时提示清理
CACHE_WARN_GB=10
# 单个文件超过多少 GiB 列入“大文件”
BIG_FILE_GB=5
# 超过多少天未改动视为“很早下的”
OLD_DAYS=90

# 目录位置：DATA_ROOTS 留空表示自动探测独立挂载的数据盘
HOME_ROOT=/home
#DATA_ROOTS="/data /ssd"

# 扫描性能
SCAN_PARALLEL=1   # 各块盘并行扫描（不同物理设备互不抢 IO），设 0 串行
SCAN_JOBS=1       # 单块盘内按一级目录分片的并行度；RAID/NVMe 上可调 4~8，会明显占 IO
CONF
    chmod 0644 "$CONFIG_PATH"
    echo "已写入默认配置：$CONFIG_PATH"
}

install_units() {
    have_systemd || {
        echo "未检测到 systemd，跳过定时器安装；请自行用 cron 调用：$BIN_PATH --scan" >&2
        return 0
    }
    install -m 0644 "$SRC_DIR/$SERVICE" "$UNIT_DIR/$SERVICE"
    install -m 0644 "$SRC_DIR/$TIMER" "$UNIT_DIR/$TIMER"
    systemctl daemon-reload
    systemctl enable --now "$TIMER"
    echo "已启用定时器：$TIMER（每天凌晨 6 点扫描）"
}

first_scan() {
    [ "${NO_SCAN:-0}" = "1" ] && {
        echo "已跳过首次扫描（NO_SCAN=1）；稍后可执行：$BIN_PATH --scan"
        return 0
    }
    echo "正在执行首次扫描（盘大时需要几分钟）…"
    "$BIN_PATH" --scan
    echo "扫描完成，报告位于 $STATE_DIR"
}

case "$ACTION" in
    install)
        need_root
        install_files
        write_config
        install_units
        first_scan
        echo
        echo "完成。重新登录即可看到提示；立即预览：$BIN_PATH --test"
        ;;
    update)
        need_root
        install_files
        install_units
        if have_systemd; then
            systemctl restart "$TIMER"
        fi
        first_scan
        echo "更新完成。"
        ;;
    remove)
        need_root
        if have_systemd; then
            systemctl disable --now "$TIMER" 2>/dev/null || true
            rm -f "$UNIT_DIR/$TIMER" "$UNIT_DIR/$SERVICE"
            systemctl daemon-reload
        fi
        rm -f "$PROFILE_PATH" "$BIN_PATH"
        rm -rf "$STATE_DIR"
        echo "已移除脚本、登录钩子、定时器与缓存"
        if [ "$PURGE" -eq 1 ]; then
            rm -f "$CONFIG_PATH"
            echo "已删除配置：$CONFIG_PATH"
        else
            echo "保留配置：$CONFIG_PATH（--purge 可一并删除）"
        fi
        ;;
    status)
        printf "脚本：      %s\n" "$([ -x "$BIN_PATH" ] && echo "$BIN_PATH" || echo 未安装)"
        printf "登录钩子：  %s\n" "$([ -f "$PROFILE_PATH" ] && echo "$PROFILE_PATH" || echo 未安装)"
        printf "配置：      %s\n" "$([ -f "$CONFIG_PATH" ] && echo "$CONFIG_PATH" || echo 未安装)"
        if have_systemd; then
            systemctl list-timers --all "$TIMER" 2>/dev/null || true
        fi
        if [ -d "$STATE_DIR" ]; then
            printf "\n缓存文件：\n"
            ls -l "$STATE_DIR" "$STATE_DIR/users" 2>/dev/null
        fi
        ;;
esac
