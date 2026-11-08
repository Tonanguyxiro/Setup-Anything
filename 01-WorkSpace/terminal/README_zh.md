# 终端环境

[English](./README.md) | 中文

通过仓库根目录的 TUI 配置当前用户的 Zsh 和 Tmux。所有操作均不需要 root：

```bash
./setup.sh
```

使用 `↑`/`↓` 或 `j`/`k` 选择项目，按 `Enter` 确认。

<table>
  <tr><td>Zsh</td><td><a href="./zsh/.zshrc">zsh/.zshrc</a></td><td>Oh My Zsh、主题和可用插件配置</td></tr>
  <tr><td>Tmux</td><td><a href="./tmux/.tmux.conf">tmux/.tmux.conf</a></td><td>鼠标、重载快捷键和状态栏配置</td></tr>
</table>

## Zsh

TUI 优先使用 PATH 中已有的 `zsh`。如果不存在，则从 [Zsh 官方发布包](https://zsh.sourceforge.io/Arc/source.html)编译 Zsh 5.9.2，并安装到 `~/.local/opt/zsh-5.9.2`；`~/.local/bin/zsh` 是其用户级入口。这个过程需要 C 编译器、`make`、`tar`，以及 `curl` 或 `wget`，但不需要 root。

配置时，TUI 会备份现有 `~/.zshrc`，安装 [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh)，并从官方仓库安装 [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) 和 [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)。随后安装仓库提供的 `.zshrc`。取消配置会恢复原来的 `.zshrc` 并移除 TUI 添加的 Bash PATH 段，但保留已下载的 Zsh、Oh My Zsh 和插件，避免删除用户后续数据。TUI 不自动执行 `chsh`。

仓库模板不包含用户专属的 Conda 路径。只有检测到 `conda` 命令时才启用 Conda 插件。

## Tmux

TUI 要求系统中已有 `tmux`。配置时，它只在 `~/.tmux.conf` 末尾加入带边界标记的 `source-file` 段，不覆盖原有内容。取消配置只删除该受控段。当前 Tmux 服务器已经加载的设置会持续到重新加载配置或重启服务器。

## 直接命令

```bash
./setup.sh zsh configure
./setup.sh zsh status
./setup.sh zsh remove

./setup.sh tmux configure
./setup.sh tmux status
./setup.sh tmux remove
```
