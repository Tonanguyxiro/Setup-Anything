# Setup Anything

Guides and scripts for local development, remote server workspaces, and shared server disk management.

<table>
  <tr><td><a href="./01-Workspace/README.md">Workspace (Linux/macOS/WSL)</a></td><td>General, Local, HomeLab, and Remote Server</td></tr>
  <tr><td><a href="./02-Remote-Server-Management/README.md">Remote Server Management</a></td></tr>
</table>

## Usage

Run the unified entry point from the repository root:

```bash
./setup.sh
```

The menu reads keys with Bash `read` and renders with ANSI escape sequences. Use `↑`/`↓` or `j`/`k` to move and `Enter` to select. UI primitives live in [`tui/tui.sh`](./tui/tui.sh), while configuration logic remains in `setup.sh`.

- **Workspace** groups Zsh and Tmux under General and the automatic proxy under Remote Server. Local and HomeLab link to their guides.
- **Remote Server Management** checks the detailed disk warning status and uses `sudo` to install, update, or remove it.

Direct commands are also available:

```bash
./setup.sh configure          # Configure or update the user proxy
./setup.sh remove             # Remove the managed proxy configuration
./setup.sh status             # Show proxy configuration status
./setup.sh zsh configure      # Configure Zsh after backing up an existing .zshrc
./setup.sh tmux configure     # Source the repository template from .tmux.conf
./setup.sh server status      # Show detailed disk warning status (read-only)
```

### Allowing Read-Only Commands with sudo

If local policy requires root to inspect service state, an administrator can allowlist exact, audited read-only commands in `/etc/sudoers.d/`. Do not allowlist the whole `setup.sh` script, a shell, an editor, wildcard commands, or unrestricted `systemctl` operations.

Resolve executable paths with `command -v systemctl` and `command -v journalctl`, then edit a dedicated rule with `sudo visudo -f /etc/sudoers.d/server-setup-readonly`. For example:

```sudoers
Cmnd_Alias SERVER_SETUP_READONLY = /usr/bin/systemctl is-active disk_usage_warn.timer, \
    /usr/bin/systemctl is-enabled disk_usage_warn.timer, \
    /usr/bin/journalctl --no-pager -u disk_usage_warn.service
%server-operators ALL=(root) NOPASSWD: SERVER_SETUP_READONLY
```

The administrator must adjust paths and the group, then validate the file with `visudo -c`. The example uses `systemctl` operations that do not start a pager and passes `--no-pager` to `journalctl`. Command arguments are part of sudoers matching, so review and add each new read-only command explicitly instead of using `*`.

## Basic Server Setup

### Change the APT Mirror

```shell
sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.bak
```

Replace the Ubuntu archive and security mirror URLs.

```shell
sudo sed -i "s@http://.*archive.ubuntu.com@https://mirrors.sustech.edu.cn@g" /etc/apt/sources.list
sudo sed -i "s@http://.*security.ubuntu.com@https://mirrors.sustech.edu.cn@g" /etc/apt/sources.list
```

Refresh Repository Indexes

```shell
sudo apt-get update
```
