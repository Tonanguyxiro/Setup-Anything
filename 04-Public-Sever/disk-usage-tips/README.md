# Disk usage tips

Conventions for the shared data disks, plus a shell hook that reminds users of those
conventions when they `cd` into a data directory.

<table>
  <tr><td>Hook installer</td><td><a href="./install.sh">install.sh</a></td><td>Installs one folder rule at a time</td></tr>
  <tr><td>Hook source</td><td><a href="./install_disk_tips_hook.sh">install_disk_tips_hook.sh</a></td><td>The shell hook written to <code>/etc/profile.d/</code></td></tr>
  <tr><td>Disk warnings</td><td><a href="../disk-warning/disk-warning-detailed">disk-warning-detailed</a></td><td>Login warning when a disk is full, plus per-user cleanup advice（中文文档）</td></tr>
  <tr><td>Light version</td><td><a href="../disk-warning/disk-warning-light">disk-warning-light</a></td><td>Single-file <code>/home</code> usage warning</td></tr>
</table>

## Layout of the data disks

```text
/data1/ (shared/)                         # Public data, such as datasets and models
├── datasets/
├── models/
└── ...

/data2/ (private/)                        # Personal data, such as experimental results and logs
├── user1/
├── user2/
├── user3/
└── ...
```

You can use symbolic links to point to the data in `/data1` or `/data2` from your home directory. For example:

```bash
ln -s /data1/datasets ~/datasets
ln -s /data1/models ~/models

ln -s /data2/user1 ~/data
```

## Show a tip when users enter a data directory

Install one folder tip at a time as root:

```bash
sudo ./install.sh --folder /data1 --usage shared
sudo ./install.sh --folder /data2 --usage private
```

The script writes the hook to `/etc/profile.d/disk-tips.sh` and stores folder rules in `/etc/disk-tips.conf`.

After users start a new shell, the tip is shown once per shell session when they enter the configured folder or its subdirectories:

```bash
cd /data1
cd /data1/datasets
cd /data2
```

Example prompt:

```text
TIP: This disk /data1 is for shared use.

Please follow the shared-disk usage rules for your own and others' convenience.

/data1/ (shared/)                         # shared data directory
├── datasets/
├── models/
│   └── Qwen/
│       └── Qwen3-7B/
└── ...

/data2/ (private/)                        # private data directory
├── yuantong/
│   └── project1/
├── user2/
└── ...

Use symbolic links from your home directory, for example:
  ln -s /data1/datasets ~/datasets
  ln -s /data1/models ~/models
```

## Related: disk usage warnings

The tips above tell users *where* data belongs. [disk-warning-detailed](../disk-warning/disk-warning-detailed)
tells them *when to clean up*: a systemd timer scans the disks every night at 06:00 and, at login,
shows two sections whenever **any** of these is true — a disk is over 90%, the user's home is over
100G, or the user's data-disk usage is over 500G:

1. **Global** — usage, free space and the top three users per disk, plus system caches such as
   `/tmp` and `/var/log` with the command to clean each one.
2. **Current user** — how much the user holds on each disk, their largest first-level directories
   and files (flagging anything untouched for 90+ days), single files over 5G, caches such as
   `~/.cache` and conda/pip/uv/npm, and a numbered list of cleanup suggestions.

Install it as root, then check that the data disks were detected correctly:

```bash
cd ../disk-warning/disk-warning-detailed
sudo ./install.sh
/usr/local/sbin/disk_usage_warn.sh --roots
```

The data-disk names used in this document (`/data1`, `/data2`) are an example of the shared/private
split; `--roots` prints the disks that were actually detected on the machine you are on.
