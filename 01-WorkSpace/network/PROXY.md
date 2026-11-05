# 为内网服务器配置代理

前提：假设服务器的IP地址A.B.C.D，用户名为cs，当自己接入了学校/公司内网后，可以通过ssh连接到服务器上：

```bash
ssh cs@A.B.C.D
```

为了能够让服务器连上互联网，我们需要在自己的电脑上安装clash，并且将 设置为系统代码 打开。注意这里的混合代理端口被设为默认的7890。(只需要安装并启动这款软件即可，并不需要导入节点啥的)


## 直接使用 ssh 反向代理

接着，在本机上重启一个终端（后续的所有操作都需要在这个终端上进行，包括使用pip命令），执行如下指令：

```bash
ssh -R A.B.C.D:7891:127.0.0.1:7890 cs@A.B.C.D
```
该指令本质上是ssh cs@A.B.C.D，即会连接到服务器上。前面的配置参数的含义是：将服务器上的7891端口的流量转发到自己电脑的7890端口上，其中的7890需要和自己的clash中的混合代理端口相同。

然后在这个终端上执行如下命令，该命令将服务器上的https, http的流量转发到7891端口。

```bash
export https_proxy=http://127.0.0.1:7891 http_proxy=http://127.0.0.1:7891 all_proxy=socks5://127.0.0.1:7891
```
此时在服务器上就可以使用`pip install xxx`来安装网络上的Python包了。如果你想要使用conda install来安装Python包，在终端执行如下内容后，就可以使用conda install命令了。

```bash
conda config --set proxy_servers.http http://127.0.0.1:7891
conda config --set proxy_servers.https https://127.0.0.1:7891
```

## 在 github ssh 上配置反向代理

## 高级配置

### 根据本地转发端口自动配置代理

下面的配置适用于这种链路：当前服务器通过 SSH 连接到另一台能访问代理的服务器，并将远端代理端口转发到当前服务器的 `127.0.0.1:20122`。

```text
当前服务器:20122 -> SSH 隧道 -> A6000:43789
```

将以下内容加入当前服务器的 `~/.bashrc`：

```bash
# ===== Auto proxy config for local forwarded proxy ===== START

export PROXY_HOST="127.0.0.1"
export PROXY_PORT="20122"
export PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"

_port_listening() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :${PROXY_PORT} )" 2>/dev/null \
            | grep -q ":${PROXY_PORT}"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"${PROXY_PORT}" -sTCP:LISTEN >/dev/null 2>&1
    else
        timeout 1 bash -c \
            ":</dev/tcp/${PROXY_HOST}/${PROXY_PORT}" >/dev/null 2>&1
    fi
}

enable_proxy() {
    export HTTP_PROXY="${PROXY_URL}"
    export HTTPS_PROXY="${PROXY_URL}"
    export ALL_PROXY="${PROXY_URL}"

    export http_proxy="${PROXY_URL}"
    export https_proxy="${PROXY_URL}"
    export all_proxy="${PROXY_URL}"

    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="${NO_PROXY}"
}

disable_proxy() {
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
    unset http_proxy https_proxy all_proxy
    unset NO_PROXY no_proxy
}

auto_proxy() {
    if _port_listening; then
        enable_proxy
    else
        disable_proxy
    fi
}

proxy_status() {
    echo "Proxy port: ${PROXY_HOST}:${PROXY_PORT}"

    if _port_listening; then
        echo "Port status: LISTENING"
    else
        echo "Port status: NOT LISTENING"
    fi

    echo
    echo "HTTP_PROXY=${HTTP_PROXY:-<unset>}"
    echo "HTTPS_PROXY=${HTTPS_PROXY:-<unset>}"
    echo "ALL_PROXY=${ALL_PROXY:-<unset>}"
    echo "NO_PROXY=${NO_PROXY:-<unset>}"
}

# 每次启动交互式 shell 时，根据端口状态配置代理。
auto_proxy

alias proxy-on='enable_proxy'
alias proxy-off='disable_proxy'
alias proxy-check='proxy_status'
alias proxy-tunnel='ssh -N -L 127.0.0.1:20122:127.0.0.1:43789 A6000'

# ===== Auto proxy config for local forwarded proxy ===== END
```

其中，`A6000` 是 `~/.ssh/config` 中定义的 SSH Host；`43789` 是 A6000 上的代理监听端口。请根据实际环境修改 SSH Host、远端端口和 `PROXY_PORT`。

#### 公共服务器上的代理认证

在多人共用的服务器上，其他用户也可能连接 `127.0.0.1:20122`。仅监听回环地址可以阻止外部主机直接访问，但不能隔离同一台服务器上的用户。此时应在 A6000 的代理服务中启用用户名和密码认证；客户端只负责发送凭据，不能代替代理服务端的访问控制。

不要将凭据直接写入仓库中的脚本。可以创建仅当前用户可读的私有配置文件：

```bash
mkdir -p ~/.config/proxy
chmod 700 ~/.config/proxy

printf '%s\n' \
    'export PROXY_AUTH="<username>:<password>"' \
    > ~/.config/proxy/credentials.sh
chmod 600 ~/.config/proxy/credentials.sh
```

然后将前述 `~/.bashrc` 配置中定义 `PROXY_URL` 的部分改为：

```bash
export PROXY_HOST="127.0.0.1"
export PROXY_PORT="20122"

PROXY_CREDENTIALS="$HOME/.config/proxy/credentials.sh"
if [[ -r "${PROXY_CREDENTIALS}" ]]; then
    source "${PROXY_CREDENTIALS}"
fi

if [[ -n "${PROXY_AUTH:-}" ]]; then
    export PROXY_URL="http://${PROXY_AUTH}@${PROXY_HOST}:${PROXY_PORT}"
else
    export PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
fi
unset PROXY_CREDENTIALS
```

`PROXY_AUTH` 的格式是 `<username>:<password>`。如果用户名或密码包含 `@`、`:`、`/`、`#`、`%` 等 URL 保留字符，需要先对相应字符做百分号编码。私有文件可以防止凭据进入 Git，但代理 URL 仍会作为环境变量提供给当前用户启动的程序。因此，应使用权限有限的独立代理账号，并定期更换密码。

重新加载配置：

```bash
source ~/.bashrc
```

常用命令如下：

| 命令 | 作用 |
| --- | --- |
| `proxy-tunnel` | 在前台建立 SSH 本地端口转发；按 `Ctrl-C` 关闭隧道 |
| `auto_proxy` | 重新检查端口，并自动启用或关闭代理环境变量 |
| `proxy-on` | 不检查端口，直接设置代理环境变量 |
| `proxy-off` | 清除代理环境变量 |
| `proxy-check` | 显示端口和代理环境变量的当前状态 |

推荐按以下顺序使用：

1. 执行 `proxy-tunnel`，保持该终端运行。
2. 打开另一个终端。新 shell 会运行 `auto_proxy` 并检测 `20122` 端口。
3. 执行 `proxy-check`，确认端口显示为 `LISTENING`，代理变量已经设置。
4. 使用 `curl -I https://github.com` 验证网络连接。

`auto_proxy` 只在 shell 启动或手动调用时检查一次端口。如果先打开 shell、后建立隧道，需要执行 `auto_proxy`，或者重新打开一个终端。端口处于监听状态只表示本地隧道已经建立，不保证远端代理服务可用。

## 无网设置（通用）

```shell
# 使用带代理的 ssh 链接服务器，并转发端口到本地
ssh -R <server-ip>:20121:127.0.0.1:20122 <user-name>@<server-ip>

# 在服务器端设置代理
export https_proxy=http://127.0.0.1:20121 http_proxy=http://127.0.0.1:20121 all_proxy=socks5://127.0.0.1:20121
```

```config
Host 
```
