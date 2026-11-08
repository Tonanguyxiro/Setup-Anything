# Terminal Environment

English | [中文](./README_zh.md)

Use the TUI at the repository root to configure Zsh and Tmux for the current user. These operations do not require root:

```bash
./setup.sh
```

Use `↑`/`↓` or `j`/`k` to move and press `Enter` to select.

<table>
  <tr><td>Zsh</td><td><a href="./zsh/.zshrc">zsh/.zshrc</a></td><td>Oh My Zsh, theme, and available plugin settings</td></tr>
  <tr><td>Tmux</td><td><a href="./tmux/.tmux.conf">tmux/.tmux.conf</a></td><td>Mouse, reload binding, and status bar settings</td></tr>
</table>

## Zsh

The TUI first uses an existing `zsh` from PATH. If none exists, it builds Zsh 5.9.2 from the [official Zsh release](https://zsh.sourceforge.io/Arc/source.html) and installs it under `~/.local/opt/zsh-5.9.2`, with `~/.local/bin/zsh` as the user-level entry point. Building requires a C compiler, `make`, `tar`, and either `curl` or `wget`, but does not require root.

The TUI backs up `~/.zshrc`, installs [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh), and clones [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) and [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting). It then installs the repository `.zshrc` template. Removing the configuration restores the original `.zshrc` and removes the managed Bash PATH block. Downloaded Zsh, Oh My Zsh, and plugins remain in place to avoid deleting later user data. The TUI does not run `chsh`.

The template contains no user-specific Conda path. It enables the Conda plugin only when the `conda` command is available.

## Tmux

The TUI requires an existing `tmux` executable. It appends one marked `source-file` block to `~/.tmux.conf` and preserves existing content. Removing the configuration deletes only that block. Settings already loaded by a running Tmux server remain active until the configuration is reloaded or the server restarts.

## Direct Commands

```bash
./setup.sh zsh configure
./setup.sh zsh status
./setup.sh zsh remove

./setup.sh tmux configure
./setup.sh tmux status
./setup.sh tmux remove
```
