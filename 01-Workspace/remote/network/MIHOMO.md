# Mihomo HTTPS Proxy in Rootless Docker

Run Mihomo on server A and make its authenticated HTTPS proxy available to LAN clients and to applications on server B. This procedure assumes A runs Ubuntu or Debian with systemd, has a stable LAN IPv4 address, and can reach B over SSH. Run the Bash examples as the deployment user unless a command uses `sudo`.

| Client | HTTPS proxy address | Path |
| --- | --- | --- |
| LAN client | `https://192.168.50.10:43789` | A's LAN address → Mihomo |
| Application on B | `https://127.0.0.1:20122` | B's loopback → SSH reverse forward → A's LAN address → Mihomo |

Replace `192.168.50.10` with A's LAN address and `tunnel@server-b` with the SSH destination on B. The sample uses A's internet connection for outbound traffic. If you have an upstream proxy or subscription, add its outbound configuration and point the route at it.

## 1. Install Rootless Docker on A

SSH directly into A as the deployment user. The official installer can set up a separate daemon while the existing system Docker runs. Check the host prerequisites first.

```bash
command -v curl newuidmap newgidmap
if command -v getsubids >/dev/null; then
  getsubids "$(id -un)"
  getsubids -g "$(id -un)"
else
  awk -F: -v user="$(id -un)" -v uid="$(id -u)" \
    '$1 == user || $1 == uid {print FILENAME ": " $0}' /etc/subuid /etc/subgid
fi
systemctl --user show-environment >/dev/null
```

Check for a range of at least 65,536 IDs for both the UID and GID mappings. For file-backed mappings, the third field is the range size. If tools or ID ranges are missing, ask the administrator to install the required packages or allocate a free range in `/etc/subuid` and `/etc/subgid`. If the user bus is unavailable, try a fresh SSH login as the deployment user. If the error persists, ask the administrator to check the user's systemd manager and D-Bus setup (`dbus-user-session` on Ubuntu or Debian). [Docker rootless prerequisites](https://docs.docker.com/engine/security/rootless/) · [Docker user bus troubleshooting](https://docs.docker.com/engine/security/rootless/troubleshoot/)

On Ubuntu 24.04 or later with AppArmor's unprivileged user namespace restriction enabled, ask the administrator to load this profile for the deployment user's RootlessKit binary before installing Docker. Run these commands as the deployment user with authorized `sudo` access so `$HOME` resolves to the correct path.

```bash
profile_name=$(printf '%s' "$HOME/bin/rootlesskit" | sed 's@^/@@; s@/@.@g')
sudo tee "/etc/apparmor.d/$profile_name" >/dev/null <<EOF
abi <abi/4.0>,
include <tunables/global>

"$HOME/bin/rootlesskit" flags=(unconfined) {
  userns,
}
EOF
sudo apparmor_parser -r "/etc/apparmor.d/$profile_name"
```

Download and review the official installer, then run it as the deployment user. `FORCE_ROOTLESS_INSTALL=1` lets setup proceed alongside the existing system daemon. [Docker rootless troubleshooting](https://docs.docker.com/engine/security/rootless/troubleshoot/) · [Docker rootless installer](https://get.docker.com/rootless)

```bash
curl -fsSL https://get.docker.com/rootless -o "$HOME/get-docker-rootless.sh"
FORCE_ROOTLESS_INSTALL=1 sh "$HOME/get-docker-rootless.sh"
```

If a previous attempt extracted the binaries but failed to configure the user service, resolve the reported prerequisite and run `PATH="$HOME/bin:$PATH" "$HOME/bin/dockerd-rootless-setuptool.sh" install --force`. For an existing rootless installation, proceed to the service check.

```bash
export PATH="$HOME/bin:$PATH"
systemctl --user enable --now docker.service
docker context inspect rootless --format '{{.Endpoints.docker.Host}}'
docker --context rootless info --format '{{json .SecurityOptions}}'
```

Confirm the socket is `unix:///run/user/<UID>/docker.sock` and the security options include `name=rootless`. The installer selects `rootless` as your CLI context. To restore the context you used before, run `docker context use` with its name, typically `default`. The Mihomo commands explicitly select `rootless`. [Docker rootless CLI context](https://docs.docker.com/engine/security/rootless/tips/#client)

For the proxy to survive logout and start at boot, run `loginctl enable-linger "$(id -un)"`. If the host denies the request, ask the administrator to enable lingering for your account. Check it with `loginctl show-user "$(id -un)" -p Linger` and expect `Linger=yes`. [Docker rootless daemon management](https://docs.docker.com/engine/security/rootless/tips/)

## 2. Configure the HTTPS Listener on A

Check A's LAN address and choose a free TCP port. The examples use `43789`. Permit inbound TCP traffic to this address and port from the trusted LAN subnet in A's firewall or network ACL. Keep any WAN port forwarding for this service disabled.

```bash
ip -4 -br addr
ss -ltn '( sport = :43789 )'

A_LAN_IP=192.168.50.10
MIHOMO_DIR="$HOME/.config/mihomo-server"
install -d -m 700 "$MIHOMO_DIR"
```

Run the next block once for a new deployment. It creates a self-signed server certificate with IP subject alternative names for both proxy addresses. Distribute `proxy.crt` to authorized clients through a trusted channel and keep `proxy.key` and `config.yaml` on A. Share the password separately.

```bash
(
  set -eu
  umask 077
  cd "$MIHOMO_DIR"
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 365 \
    -subj '/CN=mihomo-proxy' \
    -addext "subjectAltName=IP:${A_LAN_IP},IP:127.0.0.1" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout proxy.key -out proxy.crt

  proxy_password=$(openssl rand -hex 24)
  cat > config.yaml <<EOF
allow-lan: true
mode: rule

listeners:
  - name: https-proxy
    type: http
    listen: 0.0.0.0
    port: 43789
    certificate: /root/.config/mihomo/deploy/proxy.crt
    private-key: /root/.config/mihomo/deploy/proxy.key
    users:
      - username: proxyuser
        password: "$proxy_password"

rules:
  - MATCH,DIRECT
EOF
)
```

Mihomo uses an HTTP listener with a certificate and private key to require TLS on the client-to-proxy connection. The listener's `users` list requires proxy credentials. When merging an existing profile, keep this as the sole listener and remove any inherited plain HTTP, SOCKS, mixed, or controller listeners. [Mihomo HTTP listener configuration](https://wiki.metacubex.one/en/config/inbound/listeners/http/)

## 3. Start and Verify Mihomo on A

Run the configuration check before starting the container. The publish rule binds the HTTPS listener to A's LAN IPv4 address. [Mihomo image tags](https://hub.docker.com/r/metacubex/mihomo/tags) · [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)

```bash
MIHOMO_IMAGE=metacubex/mihomo:v1.19.33
MIHOMO_MOUNT="type=bind,src=$MIHOMO_DIR,dst=/root/.config/mihomo/deploy,readonly"
MIHOMO_CONFIG=/root/.config/mihomo/deploy/config.yaml

docker --context rootless pull "$MIHOMO_IMAGE"
docker --context rootless run --rm --mount "$MIHOMO_MOUNT" \
  "$MIHOMO_IMAGE" -t -f "$MIHOMO_CONFIG" &&
docker --context rootless run -d --name mihomo --restart unless-stopped \
  --publish "$A_LAN_IP:43789:43789/tcp" --mount "$MIHOMO_MOUNT" \
  "$MIHOMO_IMAGE" -f "$MIHOMO_CONFIG"

docker --context rootless port mihomo
docker --context rootless logs --tail 50 mihomo
```

Expect a single mapping for `43789/tcp` on A's LAN address. From a LAN client, run these checks with its copy of `proxy.crt`. The first request should receive `407 Proxy Authentication Required`. The second should prompt for the proxy password and reach the destination. The third should fail because the listener requires TLS. [curl HTTPS proxy options](https://curl.se/docs/manpage.html#--proxy-cacert)

```bash
A_LAN_IP=192.168.50.10

curl -q --noproxy '' --max-time 15 \
  --proxy "https://$A_LAN_IP:43789" --proxy-cacert ./proxy.crt \
  -I https://example.com

curl -q --noproxy '' --max-time 15 \
  --proxy "https://$A_LAN_IP:43789" --proxy-cacert ./proxy.crt \
  --proxy-user proxyuser -I https://example.com

curl -q --noproxy '' --max-time 15 \
  --proxy "http://$A_LAN_IP:43789" -I https://example.com
```

## 4. Open the Reverse Tunnel from A to B

On B, check that port `20122` is free with `ss -ltn '( sport = :20122 )'`. Confirm that B's SSH policy permits remote forwarding for the tunnel account. An administrator can scope the policy to that account with this block. Validate any configuration change with `sudo sshd -t` before reloading `ssh.service` on Ubuntu or Debian. [OpenSSH server configuration](https://man.openbsd.org/sshd_config)

```sshconfig
Match User tunnel
    AllowTcpForwarding remote
    GatewayPorts no
    PermitListen 127.0.0.1:20122
```

On A, verify B's SSH host key and configure key authentication that works without prompts inside tmux. Create the session with `tmux new-session -s mihomo-tunnel bash`, then run the following commands in that session. SSH listens on B and connects each forwarded request to the proxy on A. [OpenSSH remote forwarding](https://man.openbsd.org/ssh#R)

```bash
A_LAN_IP=192.168.50.10
B_SSH=tunnel@server-b

while true; do
  ssh -NT -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -R "127.0.0.1:20122:$A_LAN_IP:43789" "$B_SSH"
  sleep 5
done
```

Detach with `Ctrl-b` then `d`. The loop reconnects after SSH exits. To inspect it, run `tmux attach-session -t mihomo-tunnel` on A. Start the tmux session again after A reboots. Docker and Mihomo start through the user service and container restart policy.

## 5. Verify the Tunnel on B

Copy `proxy.crt` to B through a trusted channel, then run the checks on B. Expect a loopback listener at `127.0.0.1:20122` and a successful HTTPS request after entering the Mihomo password.

```bash
ss -ltn '( sport = :20122 )'
curl -q --noproxy '' --max-time 15 \
  --proxy https://127.0.0.1:20122 --proxy-cacert ./proxy.crt \
  --proxy-user proxyuser -I https://example.com
```

Configure each client on B with an `https://` proxy URL, the proxy credentials, and the certificate it should trust. The repository's [automatic proxy setup](./PROXY.md) currently generates an `http://` URL. Use the HTTPS settings above for this listener.

## Stop or Update the Deployment

Stop the forward on A with `tmux kill-session -t mihomo-tunnel`. Stop the proxy with `docker --context rootless stop mihomo`. To apply a configuration or password change, rerun the check from step 3 and restart the container with `docker --context rootless restart mihomo`. To change the image or port mapping, remove the stopped container with `docker --context rootless rm -v mihomo` and run step 3 again. Renew the certificate before it expires and distribute the replacement to clients.
