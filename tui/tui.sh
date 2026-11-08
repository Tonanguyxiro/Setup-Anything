#!/usr/bin/env bash

# Reusable ANSI menu primitives. This file is sourced by setup.sh.

TUI_SELECTED=0

tui_clear() {
    printf '\033[2J\033[H'
}

tui_read_key() {
    local key suffix=""
    IFS= read -rsn1 key || return 1
    if [[ "$key" == $'\033' ]]; then
        IFS= read -rsn2 -t 0.1 suffix || true
        key+="$suffix"
    fi
    TUI_KEY=$key
}

tui_render_menu() {
    local title=$1 subtitle=$2 selected=$3
    shift 3
    local index entry label description
    local entries=("$@")

    tui_clear
    printf '\033[1;36m%s\033[0m\n' "$title"
    printf '\033[2m%s\033[0m\n\n' "$subtitle"
    for ((index = 0; index < ${#entries[@]}; index++)); do
        entry=${entries[index]}
        label=${entry%%|*}
        description=${entry#*|}
        if (( index == selected )); then
            printf '\033[1;7m  › %s  \033[0m\n' "$label"
            printf '\033[36m    %s\033[0m\n' "$description"
        else
            printf '    %s\n' "$label"
            printf '\033[2m    %s\033[0m\n' "$description"
        fi
        printf '\n'
    done
    printf '\033[2m↑/↓ or j/k to move · Enter to select\033[0m\n'
}

tui_select() {
    local title=$1 subtitle=$2
    shift 2
    local selected=0 count=$#
    (( count > 0 )) || return 1

    while true; do
        tui_render_menu "$title" "$subtitle" "$selected" "$@"
        tui_read_key || return 1
        case "$TUI_KEY" in
            $'\033[A'|k|K)
                selected=$(( (selected - 1 + count) % count ))
                ;;
            $'\033[B'|j|J)
                selected=$(( (selected + 1) % count ))
                ;;
            "")
                TUI_SELECTED=$selected
                return 0
                ;;
        esac
    done
}
