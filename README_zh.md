# 设置任何科研相关的工具、项目的初始配置与入门指南

这个项目旨在为科研人员提供一个全面的指南，帮助他们在新服务器上快速搭建和配置各种科研相关的工具和项目。无论是设置终端环境、编码环境，还是配置网络环境，或者是进行算法项目、系统项目和论文写作的准备，这个指南都将提供详细的步骤和建议。

<div class="Overview-container">
  <div class="Overview-wrapper">
    <table class="Overview">
    <tbody>
      <tr>
        <td rowspan="3"><b>设置服务器</b></td>
        <td><a href="./01-WorkSpace/terminal">Terminal</a></td>
        <td>配置终端环境</td>
      </tr>
      <tr>
        <td><a href="./01-WorkSpace/code">Coding Environment</a></td>
        <td>配置编码环境</td>
      </tr>
      <tr>
        <td><a href="./01-WorkSpace/network">Network</a></td>
        <td>配置网络环境，针对无网、无外网</td>
      </tr>
      <tr>
        <td rowspan="3"><b>科研项目</b></td>
        <td><a href="./02-Research/algorithm">算法项目</a></td>
        <td>配置算法项目环境</td>
      </tr>
      <tr>
        <td><a href="./02-Research/system">系统项目</a></td>
        <td>配置系统项目环境</td>
      </tr>
      <tr>
        <td><a href="./02-Research/latex">论文写作</a></td>
        <td>配置论文写作环境</td>
      </tr>
      <tr>
        <td rowspan="1"><b>AI Agent</b></td>
        <td><a href="./03-Agents">AI Agent 配置指南</a></td>
        <td>配置和使用 AI Agent</td>
      </tr>
    </tbody>
  </table>
  </div>
</div>


## 使用说明

在仓库根目录运行统一入口：

```bash
./setup.sh
```

菜单使用 Bash `read` 读取按键，并通过 ANSI 转义序列渲染。按 `↑`/`↓` 或 `j`/`k` 移动，按 `Enter` 确认。界面实现位于 [`tui/tui.sh`](./tui/tui.sh)，配置业务逻辑保留在 `setup.sh`。

主界面分为两部分：

- **工作环境**：只修改当前用户的文件，不调用 `sudo`。可以管理自动代理、Zsh 和 Tmux 配置；已有文件会通过受控标记或备份机制保留。
- **服务器管理**：管理系统级服务。只读状态检查不需要 root；安装、更新和卸载操作会明确调用 `sudo`。

也可以直接使用命令行子命令：

```bash
./setup.sh configure          # 配置或更新当前用户的自动代理
./setup.sh remove             # 移除自动代理配置
./setup.sh status             # 查看自动代理配置状态
./setup.sh zsh configure      # 配置 Zsh，已有 .zshrc 会先备份
./setup.sh tmux configure     # 将仓库配置接入现有 .tmux.conf
./setup.sh server status      # 只读查看详细磁盘告警状态
```

### 为只读管理命令配置 sudo 放行

如果服务器的权限策略要求 root 才能读取服务状态，管理员可以通过 `/etc/sudoers.d/` 只放行经过审核的只读命令。不要放行 `setup.sh` 整个脚本、Shell、编辑器、带通配符的命令或任意 `systemctl` 子命令。

先确认命令的绝对路径：

```bash
command -v systemctl
command -v journalctl
```

然后由管理员使用 `visudo` 编辑独立规则：

```bash
sudo visudo -f /etc/sudoers.d/server-setup-readonly
```

下面仅为示例。管理员需要根据本机路径、用户组和实际只读命令调整，并用 `visudo -c` 检查语法：

```sudoers
Cmnd_Alias SERVER_SETUP_READONLY = /usr/bin/systemctl is-active disk_usage_warn.timer, \
    /usr/bin/systemctl is-enabled disk_usage_warn.timer, \
    /usr/bin/journalctl --no-pager -u disk_usage_warn.service
%server-operators ALL=(root) NOPASSWD: SERVER_SETUP_READONLY
```

参数是 sudoers 命令匹配的一部分。示例使用不会启动分页器的 `systemctl` 子命令，并为 `journalctl` 指定 `--no-pager`。TUI 增加新的只读检查后，管理员应逐条审核并添加精确命令，不要使用 `*` 扩大权限。
