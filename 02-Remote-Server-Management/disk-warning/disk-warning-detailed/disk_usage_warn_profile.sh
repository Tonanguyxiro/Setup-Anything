# 登录时展示磁盘告警与个人用量分析（只读 /var/lib/disk-usage-warn 下的缓存，毫秒级）
# 由 install.sh 安装到 /etc/profile.d/disk_usage_warn.sh

if [ -n "${PS1-}" ] && [ -x /usr/local/sbin/disk_usage_warn.sh ]; then
    case $- in
        *i*) /usr/local/sbin/disk_usage_warn.sh 2>/dev/null ;;
    esac
fi
