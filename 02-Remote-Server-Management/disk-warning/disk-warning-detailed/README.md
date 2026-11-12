# Detailed Disk Usage Warnings

Show disk pressure, per-user usage, and cleanup suggestions at login. A systemd timer scans disks daily at 06:00. The login hook reads cached summaries. Run `--report` to read the cached full report.

<table>
  <tr><td>Scanner</td><td><a href="./disk_usage_warn.sh">disk_usage_warn.sh</a></td></tr>
  <tr><td>Installer</td><td><a href="./install.sh">install.sh</a></td></tr>
  <tr><td>Login Hook</td><td><a href="./disk_usage_warn_profile.sh">disk_usage_warn_profile.sh</a></td></tr>
  <tr><td>Scheduled Scan</td><td><a href="./disk_usage_warn.service">Service</a> and <a href="./disk_usage_warn.timer">timer</a></td></tr>
  <tr><td>Example Generator</td><td><a href="./make-example.sh">make-example.sh</a></td></tr>
  <tr><td>Lightweight Check</td><td><a href="../disk-warning-light/disk_usage_warn_light.sh">Single-file /home warning</a></td></tr>
</table>

## Warning Conditions

The login hook displays both the global and personal summaries when any condition applies.

| Condition | Default Threshold |
| --- | --- |
| Any monitored disk exceeds its usage threshold | `THRESHOLD=90` percent |
| The current user's home directory exceeds its usage threshold | `USER_HOME_WARN_GB=100` GiB |
| The current user's combined data disk usage exceeds its threshold | `USER_DATA_WARN_GB=500` GiB |

If a disk exceeds its threshold, the scan generates personal reports for all users. Otherwise, it generates reports for users who exceed a personal threshold. When no condition applies to the current user, login is silent.

The global summary lists disk utilization, free and total space, the top two users per disk, and large system caches. The personal summary lists usage by disk and up to three entries each for large files, stale directories, and caches. The full report includes more entries and per-disk tables.

## Scans and Reports

The timer invokes `disk_usage_warn.sh --scan` at idle I/O priority. The scan writes `global.txt`, `global.brief`, and personal reports under `/var/lib/disk-usage-warn/`. Each personal report belongs to its user and has mode `0600`.

The hook at `/etc/profile.d/disk_usage_warn.sh` reads the brief reports in interactive shells. It warns when the reports are more than two days old. Noninteractive SSH, SCP, and rsync sessions skip the hook.

## Data Disk Discovery

When `DATA_ROOTS` is empty, the script combines these sources:

1. Local mounts from `df --local`, excluding pseudo-filesystems, system mounts, and the home root and its descendants.
2. Directories with common names such as `data`, `data1`, `data2`, `data3`, `ssd`, `ssd1`, `nvme`, `scratch`, and `shared`. This includes data directories on the root filesystem.

After moving to another server, inspect the detected paths:

```bash
/usr/local/sbin/disk_usage_warn.sh --roots
```

For custom mount names or NFS shares, set the roots explicitly in `/etc/disk-usage-warn.conf`.

```bash
DATA_ROOTS="/mnt/bigdisk /nfs/share"
HOME_ROOT=/home
```

Data disk usage is attributed to the owners of first-level entries. When a container directory has at least two subdirectories owned by other users, the scan attributes those subdirectories to their owners. Files directly in the container remain attributed to its owner. The home usage ranking counts account directories from `getent passwd` and excludes bind mounts on another device.

## Install and Update

The installer needs root to scan other users' directories and install system files. From the repository root:

```bash
cd 02-Remote-Server-Management/disk-warning/disk-warning-detailed
sudo ./install.sh
```

The installer copies the scanner and login hook, creates a default configuration if needed, and enables `disk_usage_warn.timer`. The timer catches up after a missed run, and installation starts an initial scan.

To defer the first scan until the server is idle:

```bash
sudo NO_SCAN=1 ./install.sh
sudo systemctl start disk_usage_warn.service
```

Update the scanner, login hook, and systemd units with the commands below. The update keeps `/etc/disk-usage-warn.conf`, restarts the timer, and refreshes the reports. Configuration-only changes take effect on the next scan.

```bash
sudo ./install.sh --update
./install.sh --status
```

The root `setup.sh` menu exposes the same detailed warning operations under **Remote Server Management**.

## Remove

```bash
sudo ./install.sh --remove          # Keep the configuration
sudo ./install.sh --remove --purge  # Delete the configuration too
```

Removal deletes the scanner, login hook, systemd units, and cached reports. The installer also clears the legacy cache at `/var/log/disk_usage_warn.log` when installing over an older version.

## Configuration

Edit `/etc/disk-usage-warn.conf` or supply an environment override for debugging.

| Variable | Default | Purpose |
| --- | --- | --- |
| `THRESHOLD` | `90` | Disk usage percentage that triggers a warning |
| `USER_HOME_WARN_GB` | `100` | Personal home usage threshold in GiB |
| `USER_DATA_WARN_GB` | `500` | Combined personal data usage threshold in GiB |
| `CACHE_WARN_GB` | `10` | System cache size that triggers a cleanup suggestion in GiB |
| `BIG_FILE_GB` | `5` | Minimum large file size in GiB |
| `OLD_DAYS` | `90` | Age threshold for unmodified files and directories |
| `HOME_ROOT` | `/home` | Home directory root |
| `DATA_ROOTS` | Automatic | Space-separated data disk paths |
| `DU_TIMEOUT` | `0` | Per-invocation `du` timeout in seconds. Zero disables it. |
| `SCAN_PARALLEL` | `1` | Scan disks concurrently. Set to zero for sequential scans. |
| `SCAN_JOBS` | `1` | Concurrent first-level directory scans per disk |

## Manual Commands

```bash
# Scan only your own directories. Add --force to print below the thresholds.
/usr/local/sbin/disk_usage_warn.sh --self --force

# Read the cached full report.
/usr/local/sbin/disk_usage_warn.sh --report

# Preview live output without writing the cache.
sudo /usr/local/sbin/disk_usage_warn.sh --test

# Regenerate cached reports and show progress.
sudo /usr/local/sbin/disk_usage_warn.sh --scan --progress

# Check the next scheduled scan.
systemctl list-timers disk_usage_warn.timer
```

## Example Output

This translated excerpt shows the information in a login summary. The script emits its original messages.

```text
Disk warning (scan at 06:00)
/home: 99% used, 66G free of 3.5T
/data: 78% used, 3.2T free of 14.0T
/ssd:  95% used, 634G free of 10.5T

Your usage: /home 111G + /data 964G + /ssd 1.4T = 2.4T
Large files: 256G /ssd/user-c/models/llama-2-70b-chat
Stale directories: 32G ~/project-longctx
Caches: 54G ~/.cache

Full report: /usr/local/sbin/disk_usage_warn.sh --report
```

Generate a real sample from the installer directory:

```bash
sudo ./make-example.sh
./make-example.sh --self
sudo ./make-example.sh --readme
```

The generator writes an ignored `example-output.local.txt` file and returns ownership to the invoking user when run with `sudo`. With `--readme`, it replaces the sample above and substitutes same-length aliases for detected user names. Review directory, project, and file names before committing a generated example.

## Scan Performance

- The service runs at `Nice=19` and `IOSchedulingClass=idle`. For large disks, use `OnCalendar` to schedule the scan during a quieter period.
- The scanner runs `du` once per disk and limits the large-file search to directories large enough to contain a qualifying file. It avoids crossing mount points, using `du -x` or device checks for sharded scans.
- `SCAN_PARALLEL=0` disables parallel disk scans. On RAID or NVMe storage, increasing `SCAN_JOBS` can reduce elapsed time at the cost of higher I/O load.
- Manual progress goes to stderr when it is a terminal and counts completed first-level entries. Use `--progress` to force it and `--quiet` or `--no-progress` to suppress it.
- Redirected output omits ANSI colors. Set `NO_COLOR=1` to disable color explicitly.
- If `/home` shares the root filesystem, its capacity reflects that filesystem.
