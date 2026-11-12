# Codex on a Server with Restricted Internet Access

Use VS Code Remote-SSH and a local Clash proxy to give Codex on the server internet access. This example uses proxy port `20122` and OAuth callback port `1455`.

## Check the Local Proxy

Start Clash and confirm that it listens on `127.0.0.1:20122`. On Windows, check with:

```powershell
netstat -ano | findstr 20122
```

## Forward the Proxy and OAuth Callback

Add the following host to your local SSH configuration. On Windows, the file is `C:\Users\<username>\.ssh\config`.

```sshconfig
Host my-remote-server
  HostName <server-ip-or-hostname>
  Port <ssh-port>
  User <username>
  RemoteForward 20122:127.0.0.1:20122
  LocalForward 1455:127.0.0.1:1455
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

`RemoteForward` lets the server reach your local proxy. `LocalForward` lets the local browser reach the OAuth callback listener on the server. If you are setting up both forwards from the command line without the host entry, use:

```bash
ssh -R 20122:127.0.0.1:20122 -L 1455:127.0.0.1:1455 my-remote-server
```

Add `-N` if you only need the tunnel.

## Configure the Remote Environment

For remote Bash sessions, follow [Automatic Proxy Configuration](./PROXY.md#automatic-proxy-configuration). For VS Code Remote-SSH, open **Preferences: Open User Settings (JSON)** locally and add:

```json
{
  "remote.SSH.remoteEnvironment": {
    "ALL_PROXY": "socks5h://127.0.0.1:20122",
    "all_proxy": "socks5h://127.0.0.1:20122",
    "NO_PROXY": "localhost,127.0.0.1,::1",
    "no_proxy": "localhost,127.0.0.1,::1"
  }
}
```

Run **Remote-SSH: Kill VS Code Server on Host** from the command palette, then reconnect.

## Verify the Forward

Run `ss -tulnp | grep 20122` on the server. Look for a listener on `127.0.0.1:20122`.

[Original Remote-SSH and Codex walkthrough](https://zhuanlan.zhihu.com/p/2009590635548665051)
