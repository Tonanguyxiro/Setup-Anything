#!/bin/sh
# Install a shell hook that shows a folder usage tip when users enter it.

set -eu

HOOK_PATH=${HOOK_PATH:-/etc/profile.d/disk-tips.sh}
CONFIG_PATH=${CONFIG_PATH:-/etc/disk-tips.conf}

usage() {
    echo "Usage: $0 --folder /path --usage shared"
}

FOLDER=
USAGE=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --folder)
            [ "$#" -ge 2 ] || {
                usage
                exit 1
            }
            FOLDER=$2
            shift 2
            ;;
        --usage)
            [ "$#" -ge 2 ] || {
                usage
                exit 1
            }
            USAGE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ -z "$FOLDER" ] || [ -z "$USAGE" ]; then
    usage
    exit 1
fi

case "$FOLDER" in
    /*) ;;
    *)
        echo "--folder must be an absolute path"
        exit 1
        ;;
esac

case "$FOLDER$USAGE" in
    *'|'*)
        echo "--folder and --usage must not contain |"
        exit 1
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root, for example: sudo $0 --folder $FOLDER --usage $USAGE"
    exit 1
fi

mkdir -p "$(dirname "$CONFIG_PATH")"
touch "$CONFIG_PATH"

tmp_config=$(mktemp)
awk -F'|' -v folder="$FOLDER" '$1 != folder { print }' "$CONFIG_PATH" > "$tmp_config"
printf '%s|%s\n' "$FOLDER" "$USAGE" >> "$tmp_config"
cat "$tmp_config" > "$CONFIG_PATH"
rm -f "$tmp_config"
chmod 644 "$CONFIG_PATH"

cat > "$HOOK_PATH" <<'EOF'
# Show folder usage tips when users enter configured directories.
# Config format: /absolute/path|usage

disk_tips_config=${DISK_TIPS_CONFIG:-/etc/disk-tips.conf}

disk_tips_show() {
    disk_tips_folder=$1
    disk_tips_usage=$2

    printf '\n'
    printf 'TIP: This disk %s is for %s use.\n\n' "$disk_tips_folder" "$disk_tips_usage"
    printf "Please follow the %s-disk usage rules for your own and others' convenience.\n\n" "$disk_tips_usage"

    while IFS='|' read -r folder usage; do
        [ -n "$folder" ] || continue
        printf '%s/ (%s/)                         # %s data directory\n' "$folder" "$usage" "$usage"
        case "$usage" in
            shared|public)
                printf '├── datasets/\n'
                printf '├── models/\n'
                printf '│   └── Qwen/\n'
                printf '│       └── Qwen3-7B/\n'
                printf '└── ...\n'
                ;;
            private|personal)
                printf '├── %s/\n' "${USER:-user1}"
                printf '│   └── project1/\n'
                printf '├── user2/\n'
                printf '└── ...\n'
                ;;
            *)
                printf '└── ...\n'
                ;;
        esac
        printf '\n'
    done < "$disk_tips_config"

    printf 'Use symbolic links from your home directory, for example:\n'
    case "$disk_tips_usage" in
        shared|public)
            printf '  ln -s %s/datasets ~/datasets\n' "$disk_tips_folder"
            printf '  ln -s %s/models ~/models\n' "$disk_tips_folder"
            ;;
        private|personal)
            printf '  ln -s %s/%s ~/data\n' "$disk_tips_folder" "${USER:-user1}"
            ;;
        *)
            printf '  ln -s %s ~/data\n' "$disk_tips_folder"
            ;;
    esac
    printf '\n'
}

disk_tips_maybe_show() {
    [ -r "$disk_tips_config" ] || return 0

    while IFS='|' read -r folder usage; do
        [ -n "$folder" ] || continue

        case "${PWD:-}" in
            "$folder"|"$folder"/*)
                shown_var="DISK_TIPS_SHOWN_$(printf '%s' "$folder" | tr -c 'A-Za-z0-9' '_')"
                eval "already_shown=\${$shown_var:-}"
                if [ -z "$already_shown" ]; then
                    disk_tips_show "$folder" "$usage"
                    eval "$shown_var=1"
                    export "$shown_var"
                fi
                ;;
        esac
    done < "$disk_tips_config"
}

case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -n "${BASH_VERSION:-}" ] || [ -n "${ZSH_VERSION:-}" ]; then
    cd() {
        builtin cd "$@" || return
        disk_tips_maybe_show
    }

    disk_tips_maybe_show
fi
EOF

chmod 644 "$HOOK_PATH"

echo "Installed disk tip:"
echo "  folder: $FOLDER"
echo "  usage:  $USAGE"
echo "Hook: $HOOK_PATH"
echo "Config: $CONFIG_PATH"
