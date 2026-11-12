# Proxy Setup for an Internal Server

This guide assumes you can SSH to the server from your local computer. Start Clash and check its mixed proxy port. The first example uses port `7890`.

## SSH Reverse Forwarding

On your local computer, forward the server's loopback port `7891` to the local proxy.

```bash
ssh -R 127.0.0.1:7891:127.0.0.1:7890 cs@A.B.C.D
```

In that SSH session, set the proxy variables before running tools such as `pip`.

```bash
export https_proxy=http://127.0.0.1:7891 http_proxy=http://127.0.0.1:7891 all_proxy=socks5://127.0.0.1:7891
```

To set the proxy in Conda's configuration:

```bash
conda config --set proxy_servers.http http://127.0.0.1:7891
conda config --set proxy_servers.https http://127.0.0.1:7891
```

## Automatic Proxy Configuration

Run `./setup.sh` from the repository root and select **Workspace → Remote Server → Automatic proxy**. The menu configures, updates, inspects, or removes the current user's proxy. The same actions are available as `./setup.sh configure`, `./setup.sh status`, and `./setup.sh remove`.

The manual setup below assumes the shell can reach a forwarded proxy at `127.0.0.1:20122`. The `proxy-tunnel` alias illustrates a local forward to an SSH host named `A6000`, where the proxy listens on port `43789`. If a reverse forward already listens on port `20122`, use that listener.

Add this block to `~/.bashrc`:

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

# Set or clear the proxy when an interactive shell starts.
auto_proxy

alias proxy-on='enable_proxy'
alias proxy-off='disable_proxy'
alias proxy-check='proxy_status'
alias proxy-tunnel='ssh -N -L 127.0.0.1:20122:127.0.0.1:43789 A6000'

# ===== Auto proxy config for local forwarded proxy ===== END
```

Set the SSH alias and proxy ports for your environment.

### Proxy Authentication on Shared Servers

Other users on the same server can connect to a loopback listener. Enable username and password authentication on the proxy service if only authorized users should use it. Store the credentials in a private file outside the repository.

```bash
mkdir -p ~/.config/proxy
chmod 700 ~/.config/proxy

printf '%s\n' \
    'export PROXY_AUTH="<username>:<password>"' \
    > ~/.config/proxy/credentials.sh
chmod 600 ~/.config/proxy/credentials.sh
```

Replace the `PROXY_URL` definition in the Bash configuration with this block:

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

Percent-encode URL-reserved characters in the username or password before setting `PROXY_AUTH`. Programs that you start can read the resulting proxy URL from their environment.

### Verify the Proxy

```bash
source ~/.bashrc
```

If using the local-forward example, run `proxy-tunnel` in a separate terminal and keep it open.

| Command | Action |
| --- | --- |
| `proxy-tunnel` | Open the foreground SSH local forward. Press Ctrl-C to close it. |
| `auto_proxy` | Check the listener and set or clear proxy variables. |
| `proxy-on` | Set proxy variables immediately. |
| `proxy-off` | Clear proxy variables. |
| `proxy-check` | Show listener and proxy variable status. |

After opening the tunnel, open a new shell or run `auto_proxy`. Run `proxy-check` to check the listener, then use `curl -I https://github.com` to verify that traffic reaches the internet.

## Reverse Forwarding with a Different Remote Port

This example forwards remote port `20121` to local proxy port `20122`.

```bash
# Open a reverse tunnel from the local computer
ssh -R 127.0.0.1:20121:127.0.0.1:20122 <user-name>@<server-ip>

# Set the proxy variables on the server
export https_proxy=http://127.0.0.1:20121 http_proxy=http://127.0.0.1:20121 all_proxy=socks5://127.0.0.1:20121
```
