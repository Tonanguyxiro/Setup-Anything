#!/bin/sh
# 生成输出示例：
#   ./make-example.sh            只生成本地真实示例 example-output.local.txt（已 gitignore）
#   ./make-example.sh --readme   再生成脱敏版，并写回 README.md 的示例代码块
#   ./make-example.sh --self     用 --self 生成（只含当前用户部分，普通用户可用）
#
# 建议用 root 跑，否则其他用户的家目录统计不到：
#   sudo ./make-example.sh --readme
#
# 脱敏规则：把 /home 下的真实用户名按出现顺序替换成 user-a、user-b…（root 保留）。
# 目录名、项目名、文件名不会自动脱敏，写进 README 前请自己再看一眼。

set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT=${SCRIPT:-$SRC_DIR/disk_usage_warn.sh}
REAL_FILE=${REAL_FILE:-$SRC_DIR/example-output.local.txt}
README=${README:-$SRC_DIR/README.md}
HOME_ROOT=${HOME_ROOT:-/home}

MODE=--test
WRITE_README=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --readme) WRITE_README=1 ;;
        --self) MODE=--self ;;
        --test) MODE=--test ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
    esac
    shift
done

[ -x "$SCRIPT" ] || { echo "找不到可执行的 $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

echo "正在扫描（$MODE，盘大时需要几分钟）…" >&2
# stderr 直通终端：进度条和警告都要看得见；stdout 才是报告本身
NO_COLOR=1 "$SCRIPT" "$MODE" --force > "$TMP/raw.txt" || exit 1

{
    printf '# 本机真实输出（已去色），生成于 %s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '# 命令：%s %s %s\n' "$([ "$(id -u)" -eq 0 ] && echo sudo || echo '')" "$SCRIPT" "$MODE"
    [ "$(id -u)" -eq 0 ] || printf '# 注意：非 root 运行，/home 下其他用户的用量统计不到\n'
    printf '# 本文件含真实用户名与路径，已在 .gitignore 中，不要提交。\n\n'
    cat "$TMP/raw.txt"
} > "$REAL_FILE"
give_back() { # sudo 运行时把文件还给调用者，别在仓库里留下 root 属主的文件
    [ -n "${SUDO_UID:-}" ] || return 0
    chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$1" 2>/dev/null || true
}

give_back "$REAL_FILE"
echo "已写入真实示例：$REAL_FILE" >&2

[ "$WRITE_README" -eq 1 ] || exit 0

# ---- 脱敏：按在报告中首次出现的顺序，把用户名换成 user-a、user-b…
users=$(getent passwd 2>/dev/null |
    awk -F: -v r="$HOME_ROOT" '$6 ~ "^" r "/[^/]+$" {print $1}' | sort -u)

: > "$TMP/order.txt"
for u in $users; do
    [ "$u" = root ] && continue
    line=$(grep -n -w -m1 -- "$u" "$TMP/raw.txt" 2>/dev/null | cut -d: -f1) || true
    [ -n "${line:-}" ] && printf "%s\t%s\n" "$line" "$u" >> "$TMP/order.txt"
done

: > "$TMP/sed.txt"
i=0
sort -n "$TMP/order.txt" | cut -f2 | while IFS= read -r u; do
    i=$((i + 1))
    # 别名与原用户名**等长**，否则表格列会错位
    alias=$(awk -v n="$i" -v len="${#u}" 'BEGIN {
        s = ""
        while (n > 0) { r = (n - 1) % 26; s = sprintf("%c", 97 + r) s; n = int((n - 1) / 26) }
        split("user-,usr-,u-,u,", prefixes, ",")
        for (k = 1; k <= 5; k++) {
            cand = prefixes[k] s
            if (length(cand) <= len) break
        }
        while (length(cand) < len) cand = cand substr(s, length(s), 1)
        print substr(cand, 1, len)
    }')
    printf 's/\\b%s\\b/%s/g\n' "$u" "$alias" >> "$TMP/sed.txt"
done

if [ -s "$TMP/sed.txt" ]; then
    sed -f "$TMP/sed.txt" "$TMP/raw.txt" > "$TMP/san.txt"
    echo "已脱敏用户名：$(wc -l < "$TMP/sed.txt") 个" >&2
else
    cp "$TMP/raw.txt" "$TMP/san.txt"
fi

# ---- 写回 README 中第一个 ```text 代码块
awk -v f="$TMP/san.txt" '
    BEGIN { while ((getline line < f) > 0) buf = buf line "\n" }
    /^```text$/ && !done { print; printf "%s", buf; skip = 1; done = 1; next }
    skip && /^```$/ { skip = 0; print; next }
    skip { next }
    { print }
' "$README" > "$TMP/README.md"

if grep -q '^```text$' "$README"; then
    mv "$TMP/README.md" "$README"
    give_back "$README"
    echo "已更新 README.md 的示例代码块" >&2
    echo "请自己再确认一遍：目录名/项目名/文件名没有自动脱敏。" >&2
else
    echo "README.md 里没有 \`\`\`text 代码块，未改动" >&2
    exit 1
fi
