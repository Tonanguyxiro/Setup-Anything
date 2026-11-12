# Managed by Server-Setup TUI

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="jonathan"

ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="true"

plugins=(git sudo)

if [[ -d "${ZSH_CUSTOM:-$ZSH/custom}/plugins/zsh-autosuggestions" ]]; then
    plugins+=(zsh-autosuggestions)
fi

if [[ -d "${ZSH_CUSTOM:-$ZSH/custom}/plugins/zsh-syntax-highlighting" ]]; then
    plugins+=(zsh-syntax-highlighting)
fi

if command -v conda >/dev/null 2>&1; then
    plugins+=(conda)
fi

source "$ZSH/oh-my-zsh.sh"
