

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
