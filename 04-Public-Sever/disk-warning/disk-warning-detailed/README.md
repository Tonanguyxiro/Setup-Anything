# 磁盘用量告警（详细版）

服务器登录时提示磁盘压力，并给出针对**当前登录用户**的用量分析与清理建议。
登录看到的是 **十几行的精简版**，详细表格版用 `--report` 按需查看。
扫描由 systemd timer 每天凌晨 6 点在后台完成，登录时只读缓存文件，**不会拖慢登录**（实测约 20ms）。

<table>
  <tr><td>主脚本</td><td><a href="./disk_usage_warn.sh">disk_usage_warn.sh</a></td><td>扫描与渲染，支持 --scan / --self / --test</td></tr>
  <tr><td>安装器</td><td><a href="./install.sh">install.sh</a></td><td>安装 / 更新 / 移除 / 状态</td></tr>
  <tr><td>登录钩子</td><td><a href="./disk_usage_warn_profile.sh">disk_usage_warn_profile.sh</a></td><td>装到 /etc/profile.d/，只读缓存</td></tr>
  <tr><td>定时任务</td><td><a href="./disk_usage_warn.service">disk_usage_warn.service</a> / <a href="./disk_usage_warn.timer">disk_usage_warn.timer</a></td><td>每天 06:00 后台扫描</td></tr>
  <tr><td>示例生成</td><td><a href="./make-example.sh">make-example.sh</a></td><td>生成本地真实示例，并可脱敏写回 README</td></tr>
  <tr><td>轻量版</td><td><a href="../disk-warning-light">disk-warning-light</a></td><td>只看 /home 使用率的单文件版本</td></tr>
</table>

## 触发条件

**满足任一条件，登录时就同时显示两部分信息**：

| # | 条件 | 默认阈值 |
|---|------|----------|
| 1 | 任一块盘使用率超标 | `THRESHOLD=90`（%） |
| 2 | 当前用户 `/home` 用量超标 | `USER_HOME_WARN_GB=100`（GiB） |
| 3 | 当前用户数据盘合计用量超标 | `USER_DATA_WARN_GB=500`（GiB） |

也就是说：盘满了，所有人登录都会看到全局情况**和**自己的用量分析；盘没满但自己用得多，同样两部分都给出，便于对照全局判断该清什么。三条都不满足时完全静默。

## 两部分内容

登录时显示的是精简版，总共十几行：

| 部分 | 内容 |
|------|------|
| 一、全局信息 | **一行**磁盘总览（各盘已用百分比 + 剩余/总量，超阈值标红）；**一行**各盘占用最多的**两个**用户；**一段**系统缓存清理建议（只列真正超标的，命令写在括号里） |
| 二、当前用户信息 | **一行**用量总览（`/home 111G + /data 964G + /ssd 1.4T = 2.4T`）；**需要处理**：过大文件（同一目录下的多个大文件合并成一行，标出文件数）、长期未动、缓存临时文件，每类最多 3 条且全部标红，多的折叠成「另有 N 项」；**清理建议**：一条一条，围绕缓存和大文件给具体命令 |

最后一行给出查看完整报告的命令。完整版（表格、Top8 明细、每盘分目录）仍然每次扫描都生成，
随时可看，不重新扫描：

```bash
/usr/local/sbin/disk_usage_warn.sh --report
```

## 工作方式

```
systemd timer（每天 06:00，idle 优先级）
    └── disk_usage_warn.sh --scan        # du 扫描 /home 与各数据盘各一次
            ├── global.txt / global.brief          # 全局：完整版 + 精简版，每次扫描都生成
            └── users/<user> 与 users/<user>.brief  # 个人：完整版 + 精简版，0600 属该用户
                                                    # 有盘超阈值 → 为所有用户生成
                                                    # 否则 → 只为用量超标的用户生成
               （都在 /var/lib/disk-usage-warn/ 下）

用户登录
    └── /etc/profile.d/disk_usage_warn.sh
            └── disk_usage_warn.sh       # cat 两份 .brief，毫秒级
                disk_usage_warn.sh --report   # 想看详细表格时再 cat 完整版
```

- 数据盘自动探测：取独立挂载的本地分区（排除 `/`、`/boot`、`/run` 等），本机即 `/data`、`/ssd`；也可在配置里写死 `DATA_ROOTS`。
- 数据盘的用量按一级目录/文件的**属主**归集，所以 `root` 名下通常是 `datasets/`、`models/` 这类公共数据。
- 个人报告是 0600 且属主为本人，别人看不到你的目录结构。
- 报告超过 2 天没刷新（正常每天刷新），登录提示里会多一行提醒去查 timer 状态。

## 换一台服务器：数据盘能自动识别吗

能。`DATA_ROOTS` 留空时按两条规则探测，取并集：

1. **独立挂载的本地磁盘分区**（`df --local`，排除 tmpfs/devtmpfs/squashfs/overlay 等伪文件系统），再排除 `/`、`/boot*`、`/run*`、`/dev*`、`/sys*`、`/proc*`、`/tmp*`、`/var*`、`/usr*`、`/etc*`、`/opt`、`/snap*`、`/media*` 以及 `$HOME_ROOT` 自身及其子目录；
2. **常见数据目录名**：`data data1 data2 data3 ssd ssd1 nvme scratch shared`（有些机器 `/data` 只是根分区下的普通目录，不是独立挂载，靠这条兜住）。

换机器后先跑一条命令确认识别结果：

```bash
/usr/local/sbin/disk_usage_warn.sh --roots
```

```text
⚠️  磁盘告警（10-20 06:00 扫描）
磁盘：/home (已用 99%, 剩余 66G/3.5T); /data (已用 78%, 剩余 3.2T/14.0T); /ssd (已用 95%, 剩余 634G/10.5T)
占用最多：/home user-a(421G) user-b(336G); /data user-a(3.7T) root(3.2T); /ssd user-b(2.9T) user-d(2.4T)
系统缓存建议清理：/tmp 34G（sudo find /tmp -xdev -mindepth 1 -mtime +7 -delete）；/var/log 143G（sudo journalctl --vacuum-time=7d）

🙋 你的用量：/home 111G + /data 964G + /ssd 1.4T = 2.4T
需要处理：
  大文件        256G  /ssd/user-c/models/llama-2-70b-chat（28 个文件，142 天未动）
  大文件        131G  /ssd/shared/llama-3.3-70b/original（8 个文件，301 天未动）
  大文件         33G  /ssd/user-c/…/long-context/slimpajama（5 个文件，875 天未动）
             另有 42 项，见完整报告
  长期未动      1.1T  /ssd/user-c（165 天未动）
  长期未动      263G  /ssd/shared/llama-3.3-70b（301 天未动）
  长期未动       32G  ~/project-longctx（101 天未动）
  缓存临时       54G  ~/.cache
  缓存临时      6.3G  ~/.vscode-server
  缓存临时      4.8G  ~/.cursor-server
             另有 2 项，见完整报告
清理建议：
  1. 缓存共 68G：逐项确认后删除，或整体 rm -rf ~/.cache/*；uv cache clean；删 ~/.vscode-server/bin 下旧版本目录
  2. 152 个大文件共 1.2T，最大的是 /data/user-c/…/training_state_rank0.pt；checkpoint 只留最优与最后一个，数据集压缩包解压后删掉
  3. 超过 90 天没动过：user-c(1.1T, 165天) llama-3.3-70b(263G, 301天) project-longctx(32G, 101天) 确认后归档或删除
  4. /home 在系统盘上最紧张，把数据集/模型/输出迁到 /data/user-c 并做软链接（mv ~/big_dir /data/user-c/ && ln -s /data/user-c/big_dir ~/big_dir）
完整报告：/usr/local/sbin/disk_usage_warn.sh --report
```

识别不对（比如数据盘叫 `/mnt/bigdisk`、或者是 **NFS 等网络盘**——`df --local` 不会收录）时，在 `/etc/disk-usage-warn.conf` 里写死即可：

```bash
DATA_ROOTS="/mnt/bigdisk /nfs/share"
HOME_ROOT=/home          # 家目录不在 /home 的机器一并改这里
```

## 安装

需要 root（扫描其他用户目录、写 `/etc/profile.d`）：

```bash
cd 04-Public-Sever/disk-warning/disk-warning-detailed
sudo ./install.sh
```

安装器会：

1. 装主脚本到 `/usr/local/sbin/disk_usage_warn.sh`；
2. 装登录钩子到 `/etc/profile.d/disk_usage_warn.sh`；
3. 写默认配置 `/etc/disk-usage-warn.conf`（已存在则保留）；
4. 启用 `disk_usage_warn.timer`（每天 06:00，错过则开机后补跑）；
5. 立刻扫描一次，让提示马上可见。

首次扫描要遍历全部数据盘，几 T 到十几 T 的盘需要几分钟到几十分钟。想晚点再扫：

```bash
sudo NO_SCAN=1 ./install.sh
sudo systemctl start disk_usage_warn.service   # 空闲时手动触发
```

装完重新登录即可看到提示；不想退出登录就先预览：

```bash
sudo /usr/local/sbin/disk_usage_warn.sh --test   # 忽略阈值，实时输出两部分
```

## 更新

改完仓库里的脚本后：

```bash
cd 04-Public-Sever/disk-warning/disk-warning-detailed
sudo ./install.sh --update
```

更新脚本、登录钩子与 systemd 单元，**保留 `/etc/disk-usage-warn.conf`**，重启 timer 并重新扫描一次。
只想改阈值不用重装，直接编辑 `/etc/disk-usage-warn.conf`，下次扫描生效（或手动 `sudo systemctl start disk_usage_warn.service`）。

查看当前状态：

```bash
sudo ./install.sh --status
```

## 移除

```bash
sudo ./install.sh --remove          # 删脚本、登录钩子、timer 与缓存，保留配置
sudo ./install.sh --remove --purge  # 连 /etc/disk-usage-warn.conf 一起删
```

旧版本把整个脚本放在 `/etc/profile.d/disk_usage_warn.sh`、缓存写在 `/var/log/disk_usage_warn.log`，`install.sh` 安装时会顺手清掉旧缓存文件；同名的 `.service`/`.timer` 会被覆盖。

## 配置

`/etc/disk-usage-warn.conf`（也可用同名环境变量临时覆盖，便于调试）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `THRESHOLD` | `90` | 磁盘使用率告警阈值（%） |
| `USER_HOME_WARN_GB` | `100` | 用户家目录超过多少 GiB 触发提示 |
| `USER_DATA_WARN_GB` | `500` | 用户数据盘合计超过多少 GiB 触发提示 |
| `CACHE_WARN_GB` | `10` | 系统缓存目录超过多少 GiB 标红提示清理 |
| `BIG_FILE_GB` | `5` | 单个文件超过多少 GiB 列入“大文件” |
| `OLD_DAYS` | `90` | 超过多少天未改动算“很早下的”，标红优先处理 |
| `HOME_ROOT` | `/home` | 家目录根 |
| `DATA_ROOTS` | 自动探测 | 数据盘列表，如 `"/data /ssd"`；留空自动探测 |
| `DU_TIMEOUT` | `0` | 单次 du 超时秒数，0 为不限制 |
| `SCAN_PARALLEL` | `1` | 各块盘并行扫描（不同物理设备互不抢 IO），设 `0` 串行 |
| `SCAN_JOBS` | `1` | 单块盘内按一级目录分片的并行度，RAID/NVMe 上可调 `4~8` |

## 手动命令

```bash
# 普通用户随时自查（只扫自己的目录，2.2T 数据实测约 12s）
/usr/local/sbin/disk_usage_warn.sh --self
/usr/local/sbin/disk_usage_warn.sh --self --force   # 什么都没超阈值时也输出

# 看本次扫描的完整报告（不重新扫描，秒出）
/usr/local/sbin/disk_usage_warn.sh --report

# 管理员：实时输出全部内容（先按登录样子预览精简版，再给完整版；不写缓存）
sudo /usr/local/sbin/disk_usage_warn.sh --test

# 管理员：重新生成缓存（timer 调用的就是这个）
sudo /usr/local/sbin/disk_usage_warn.sh --scan
sudo systemctl start disk_usage_warn.service

# 手动扫描时会显示进度；--quiet 关掉，--progress 强制开（重定向到文件时默认就是关的）
sudo /usr/local/sbin/disk_usage_warn.sh --scan --progress

# 看识别到的家目录与数据盘（换服务器时先确认）
/usr/local/sbin/disk_usage_warn.sh --roots

# 看 timer 下次什么时候跑
systemctl list-timers disk_usage_warn.timer
```

## 完整输出示例

下面是两部分都显示时的**登录输出**（精简版，共 22 行；用户名、路径与容量均为脱敏示例；
终端里 `需要处理` 整块标红，输出到文件时自动去色）。详细表格版用最后一行的 `--report` 查看。

### 本地怎么更新示例

```bash
cd 04-Public-Sever/disk-warning/disk-warning-detailed

sudo ./make-example.sh            # 只生成本机真实示例 example-output.local.txt（已 gitignore）
sudo ./make-example.sh --readme   # 再把脱敏版写回本 README 的示例代码块
./make-example.sh --self          # 不用 sudo，只生成“当前用户”那一部分
```

- 真实示例写进 `example-output.local.txt`，该文件和 `*.local.txt` 都已在本目录 `.gitignore` 里，不会进仓库。
- `--readme` 会把 `/home` 下的真实用户名按出现顺序换成 `user-a`、`user-b`…（**等长替换**，表格不会错位），`root` 保留。
- **目录名、项目名、文件名不会自动脱敏**，写回 README 后请自己扫一眼再提交。
- 用 `sudo` 跑时，生成的文件会自动 `chown` 回你本人，不会在仓库里留下 root 属主的文件。

```text
===============================================================
⚠️  磁盘告警：已有磁盘使用率超过 90%，请及时清理
    扫描时间：2026-10-19 06:00:12
===============================================================

📊 磁盘总览
挂载点        | 使用率 |    已用 / 总量 |    剩余 | 状态
--------------+--------+----------------+---------+---------------
/home         |    99% |    3.4T / 3.5T |     66G | ⚠ 已超过 90%
/data         |    78% |  10.8T / 14.0T |    3.2T | 正常
/ssd          |    95% |   9.9T / 10.5T |    634G | ⚠ 已超过 90%

👥 各盘占用最多的三个用户
磁盘      | No.1                | No.2                | No.3
----------+---------------------+---------------------+---------------------
/home     | user-a(421G)        | user-b(336G)        | user-c(111G)
/data     | root(5.3T)          | user-a(3.3T)        | user-c(953G)
/ssd      | root(5.8T)          | user-d(2.1T)        | user-c(1.1T)
    数据盘按一级目录/文件的属主归集，root 名下一般是公共数据集与模型

🧹 系统级缓存 / 临时目录（超过 10G 提示清理）
目录                |    占用 | 建议
--------------------+---------+-----------------------------------------------
/tmp                |     34G | ⚠ 清理 7 天前的残留：sudo find /tmp -xdev -mindepth 1 -mtime +7 -delete
/var/tmp            |      7M | 正常
/var/cache          |    816M | 正常
/var/log            |    143G | ⚠ 清理日志：sudo journalctl --vacuum-time=7d
/var/lib/docker     |    287G | ⚠ 清理无用镜像与构建缓存：sudo docker system prune -a

===============================================================
🙋 user-c 的用量分析与清理建议
    扫描时间：2026-10-19 06:04:41
===============================================================

📦 你的用量分布
位置                      |    占用 | 说明
--------------------------+---------+-----------------------------------
/home/user-c              |    111G | 占 /home 的 3.1%
/data（属于你的目录）     |    953G | 共 2 个一级条目
/ssd（属于你的目录）      |    1.1T | 共 1 个一级条目
合计                      |    2.2T | 提示阈值：/home 100G，数据盘 500G

📁 家目录下较大的一级目录与文件（Top 8）
名称                            |    占用 |  最近改动 | 说明
--------------------------------+---------+-----------+-----------------------------
.cache                          |     54G |    0 天前 | 
project-longctx                 |     32G |  101 天前 | ⚠ 超过 90 天未改动，优先确认
.vscode-server                  |    6.3G |    0 天前 | 
.cursor-server                  |    4.8G |   46 天前 | 
.npm                            |    3.4G |  110 天前 | ⚠ 超过 90 天未改动，优先确认
project-train                   |    1.9G |   38 天前 | 
project-agent                   |    1.6G |   40 天前 | 
.rustup                         |    1.4G |  181 天前 | ⚠ 超过 90 天未改动，优先确认

📁 /data 下属于你的一级目录（Top 5）
名称                            |    占用 |  最近改动 | 最大子目录
--------------------------------+---------+-----------+-----------------------------
user-c                          |    953G |   35 天前 | train-data (833G)
shared-tool                     |      0K |   59 天前 | -

📁 /ssd 下属于你的一级目录（Top 5）
名称                            |    占用 |  最近改动 | 最大子目录
--------------------------------+---------+-----------+-----------------------------
user-c                          |    1.1T |  165 天前 | models (613G)

🗂  大文件（单个 > 5G，Top 8）
   大小 |  最近改动 | 路径
--------+-----------+-------------------------------------------------
    20G |   38 天前 | /data/user-c/train-data/outputs/run-14b/step20/training_state_rank0.pt
    18G |  234 天前 | /ssd/user-c/datasets/long-context/corpus.tar.gz
    15G |  333 天前 | /ssd/user-c/models/llama-3.1-8b/original/consolidated.00.pth
    10G |  234 天前 | /ssd/user-c/datasets/long-context/eval-data.tar.gz
   9.3G |  142 天前 | /ssd/user-c/models/llama-2-7b-chat/pytorch_model-00001-of-00002.bin
   9.3G |  142 天前 | /ssd/user-c/models/llama-2-70b-chat/pytorch_model-00011-of-00015.bin

🧰 缓存 / 临时文件（合计约 68G）
目录                        |    占用 | 清理方式
----------------------------+---------+---------------------------------------
~/.cache                    |     54G | 逐项确认后删除，或整体 rm -rf ~/.cache/*
~/.cache/uv                 |     53G | uv cache clean
~/.vscode-server            |    6.3G | 删除 ~/.vscode-server/bin 下旧版本目录
~/.cursor-server            |    4.8G | 删除 ~/.cursor-server/bin 下旧版本目录
~/.npm                      |    3.4G | npm cache clean --force
~/.triton                   |    1.2G | 确认不再需要后删除

💡 清理建议
1. 缓存已占 68G，先清缓存收益最大：pip cache purge；conda clean -a；uv cache clean；清理 ~/.cache/huggingface/hub 下过期模型
2. 以下目录超过 90 天未改动，确认后归档或删除：project-longctx(32G)
3. /home 在系统盘上、空间最紧张，把数据集/模型/实验输出迁到数据盘并做软链接：
   mv ~/big_dir /data/user-c/ && ln -s /data/user-c/big_dir ~/big_dir
4. 数据盘已占 2.1T：公共数据集/模型改用共享目录（如 /data/datasets、/data/models），不再训练的 checkpoint 只留最优与最后一个
5. 自查命令：du -xh --max-depth=1 /home/user-c | sort -hr | head -20
   find /home/user-c -xdev -type f -size +5G -mtime +90 -exec ls -lh {} +
```

## 扫描性能与进度

### 进度显示（只在手动运行时出现）

手动跑 `--scan` / `--self` / `--test` 时，**stderr 是终端**才显示进度；systemd timer 跑的时候
stderr 不是终端，自动静默，不会往 journal 里灌刷新字符。进度全部走 stderr，所以
`--test > example-output.local.txt` 这种重定向不会被污染。

```text
[1/3] 扫描磁盘：/home /data /ssd
  扫描中  home 34/36  data 22/41  ssd 11/17   00:12
[2/3] 生成全局报告
[3/3] 生成用户报告（34 个用户，只对大目录做大文件扫描）
  [##################------]  75%  26/34  user-x  01:48
```

百分比是**真实进度**不是动画：`du` 每扫完一个一级目录就输出一行（单进程模式用 `stdbuf -oL`
行缓冲实时统计；分片模式数已完成的分片文件），分母是各盘的一级条目数。
`--progress` 强制开，`--quiet` / `--no-progress` 强制关。

### 三条提速手段（已内置）

| 手段 | 说明 |
|------|------|
| 各盘并行 | 三块盘同时扫，墙钟从"求和"变成"取最大"；`SCAN_PARALLEL=0` 可关 |
| 盘内分片并行 | `SCAN_JOBS=4~8` 时按一级目录分片跑多个 `du`；本机实测 61.7s → 50.3s（热缓存，瓶颈在元数据 CPU；冷缓存的 RAID 上差距更大） |
| 大文件扫描剪枝 | 只进入 `du` 已知 ≥ `BIG_FILE_GB` 的一级目录——小目录里装不下更大的文件，大部分用户的树直接跳过 |

还没做、需要动机器的两个选项：

- **XFS 用户配额**：本机 `/`、`/data`、`/ssd` 挂载参数都是 `noquota`。如果开 `uquota`，
  `xfs_quota -c 'report -u'` 能**零遍历**秒出每用户用量，"各盘 Top3"就完全不用 `du`。
  代价是要 remount（根分区基本等于重启）。
- **放宽 IO 优先级**：service 里是 `IOSchedulingClass=idle`，机器上有人跑任务时扫描会被一直让路。
  改成 `best-effort` 会快，但会和业务抢 IO。

### 属主归集：容器目录会下钻一层

数据盘按一级目录的属主归集，但像 `/ssd/home`、`/data/bak` 这种 **root 名下的"容器目录"**
里装的其实是各用户自己的目录，整块记到 `root` 头上没有任何指导意义。所以当一个目录里
**有 2 个以上子目录属于别人**时，会下钻一层按子目录各自的属主归集，父目录里散落的文件
仍记在父目录属主名下。本机的效果：

```text
下钻前：/ssd | root(5.8T)     | xinhao(2.1T)  | yuantong(1.1T)
下钻后：/ssd | user-b(2.9T)   | user-d(2.4T)  | user-c(1.4T)
```

另外 `/home` 的 Top3 只统计 `getent passwd` 里真实存在的用户目录，`/home/shared` 这种
**绑定挂载到别的盘**的目录会按设备号排除，不会和数据盘重复计算。

## 注意事项

- **扫描成本**：`--scan` 对每块盘各做一次 `du`，再对需要出报告的用户做一次大文件 `find`。service 里已设 `Nice=19` + `IOSchedulingClass=idle`，定时点也放在凌晨 6 点；盘特别大时可把 `OnCalendar` 再往业务低谷调。
- **不跨挂载点**：`du` 带 `-x`；分片并行模式下改为按设备号过滤一级条目（分片是从一级目录内部开始扫的，`-x` 挡不住挂载点），效果一致，`/home/shared` 这类绑定挂载不会被重复计入。
- **非交互 shell 不输出**：登录钩子只在 `$PS1` 非空且 shell 为交互模式时执行，`scp`、`rsync`、`ssh host cmd` 不受影响。
- **无色输出**：输出到管道/文件时自动去掉 ANSI 颜色；也可设 `NO_COLOR=1`。
- **非 root 跑 `--scan`** 只能统计到自己有权限的目录，会打印一行警告；给普通用户用的是 `--self`。
- **`/home` 与 `/` 同盘**（本机就是）：全局表里 `/home` 一行显示的是 `/` 的容量，这是预期行为。
