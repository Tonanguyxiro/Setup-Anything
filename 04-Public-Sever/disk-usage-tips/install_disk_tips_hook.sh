#!/bin/sh
# Install a shell hook that shows shared-disk tips when users enter /data1 or /data2.

set -eu

HOOK_PATH=${HOOK_PATH:-/etc/profile.d/disk-tips.sh}
TIP_ROOTS=${TIP_ROOTS:-"/data1 /data2"}

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root, for example: sudo sh $0"
    exit 1
fi

cat > "$HOOK_PATH" <<'EOF'
# Show shared-disk usage tips when entering public data directories.
# This file is installed by Sever-Setup/04-Public-Sever/disk-tips/install_disk_tips_hook.sh.

disk_tips_show() {
    cat <<TIP

Please follow the shared-disk usage rules for your own and others' convenience.  

Shared disk layout:

/data1/ (shared/)                         # Public data, such as datasets and models
├── datasets/
├── models/
└── ...

/data2/ (private/)                        # Personal data, such as experimental results and logs
├── user1/
├── user2/
├── user3/
└── ...

Tip: use symbolic links from your home directory, for example:
  ln -s /data1/datasets ~/datasets
  ln -s /data1/models ~/models
  ln -s /data2/$USER ~/data

TIP
}

disk_tips_maybe_show() {
    case "${PWD:-}" in
        /data1|/data1/*)
            shown_var="DISK_TIPS_SHOWN__data1"
            ;;
        /data2|/data2/*)
            shown_var="DISK_TIPS_SHOWN__data2"
            ;;
        *)
            shown_var=
            ;;
    esac

    if [ -n "$shown_var" ]; then
            eval "already_shown=\${$shown_var:-}"
            if [ -z "$already_shown" ]; then
                disk_tips_show
                eval "$shown_var=1"
                export "$shown_var"
            fi
    fi
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

echo "Installed disk tips hook to $HOOK_PATH"
echo "Users will see the tip after starting a new shell and entering: $TIP_ROOTS"
