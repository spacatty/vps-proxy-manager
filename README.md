# vps-proxy-manager

Turns a cheap VPS into a box whose outgoing traffic you control from one panel:

- **CLIProxyAPI** (installed by default) sends its requests through a static ISP proxy, so the
  upstream providers see that IP instead of the datacenter's.
- Optionally, a **Tailscale exit node** for your own devices, through the same proxy.
- **Egress** is one switch: *Via proxy* (the selected proxy, with a kill switch) or *Direct* (the
  VPS's own interface and IP).
- **Firewall port rules** (Tailscale only / public / closed), editable in the panel.

```
CLIProxyAPI ----------------------\
                                   +--> mihomo --> ISP proxy --> internet     (egress: via proxy)
your devices --(Tailscale exit)---/
                                   +--> VPS interface --> internet            (egress: direct)
```

Every part can be turned off in Settings: the exit node, the kill switch, DNS through the proxy,
CLIProxyAPI management and the firewall rules.

## What's in here

| File | What it does |
|---|---|
| `setup.sh` | One-shot install on the VPS: Tailscale, mihomo, proxyctl and its panel, Docker + CLIProxyAPI |
| `proxyctl` | CLI + panel backend (Python, stdlib only) |
| `panel.html` | The web panel |
| `mihomo-base.yaml` | mihomo settings (TUN, DNS, sniffer). Proxies and the secret are added by proxyctl |

Nothing to edit before installing: no proxies are hardcoded, and every secret and key is generated
on the first run.

## Install

From Windows PowerShell:

```powershell
scp -r C:\Users\user\Desktop\vps-proxy-manager root@YOUR_VPS_IP:/root/
ssh root@YOUR_VPS_IP
```

On the VPS (Ubuntu 22.04/24.04):

```bash
cd /root/vps-proxy-manager
sudo bash setup.sh                    # or: sudo bash setup.sh --no-cliproxyapi
```

It logs into Tailscale if needed and prints the panel URL and secret. Re-running it upgrades
everything and keeps your proxies, settings and keys.

## The panel

`http://<vps-tailscale-ip>:9091`, from any device on your tailnet. Sign in with the secret
(`sudo proxyctl secret`).

- **Overview**: where each kind of traffic leaves and as which IP, warnings, the selected proxy,
  and CLIProxyAPI's endpoint, API key and management key.
- **Proxies**: add (`socks5://user:pass@host:port`, `http://...` or `host:port:user:pass`), switch,
  test latency and download/upload speed (next to the VPS's own direct speed), remove, or block everything.
- **Ports**: firewall rules and what's listening on each port.
- **Settings**: egress, exit node, kill switch, DNS, CLIProxyAPI, firewall.

## CLIProxyAPI

Installed in `/opt/CLIProxyAPI` with Docker and host networking, so its ports fall under the panel's
firewall rules and it can reach mihomo on `127.0.0.1:7890`. Its `requests.proxy-url` follows the
egress setting.

- API: `http://<vps-tailscale-ip>:8317/v1` with the API key shown in the panel.
- Its own management UI: `http://<vps-tailscale-ip>:8317/management.html` with the management key.
- **Logging in accounts** (Codex, Claude, Gemini): after you sign in, the provider sends your browser
  to `localhost:<port>`, meaning your PC. Keep this tunnel open while you log in:

  ```bash
  ssh -L 1455:127.0.0.1:1455 -L 8085:127.0.0.1:8085 -L 54545:127.0.0.1:54545 -L 51121:127.0.0.1:51121 -L 11451:127.0.0.1:11451 root@YOUR_VPS_IP
  ```

With egress *Via proxy* and no proxy added yet, CLIProxyAPI's requests are blocked rather than sent
from the VPS's own IP. Add a proxy, or switch egress to *Direct*.

## Tailscale exit node

Turn it on in Settings (or `proxyctl exit-node on`). The first time, also go to the Tailscale admin
console -> Machines -> the VPS -> **Edit route settings** -> tick **Use as exit node**, and
**Disable key expiry**.

With egress *Via proxy*:
- **Kill switch** (default on): if mihomo or the proxy is down, client traffic is dropped, never
  sent out via the VPS's IP.
- **DNS through the proxy** (default on): the VPS's resolver points at mihomo, which uses
  DNS-over-HTTPS through the proxy.
- IPv6 from clients is dropped (the proxy path is IPv4 only).

## Slow over Tailscale? Your own DERP relay

If `tailscale status` on the VPS shows your devices as `relay "xxx"` instead of `direct`, their
traffic goes through Tailscale's shared relays, which are throttled to a few Mbps. When the direct
UDP path is blocked on the way (some ISPs filter WireGuard), opening ports doesn't help. Relay
through the VPS itself instead:

```bash
sudo bash setup.sh --derp      # builds derper, runs it on 443/tcp with a self-signed cert for the IP
sudo proxyctl derp             # prints the derpMap block (also on the panel's Settings page)
```

Paste the block into the Tailscale admin console -> **Access controls**, inside the top-level `{ }`,
and save. `tailscale ping` from a device should then say `via DERP(vps)`. `OmitDefaultRegions: true`
makes every relayed connection use this VPS; set it to `false` to keep Tailscale's relays as a fallback.
Only nodes of your tailnet can use the relay (`-verify-clients`).

## CLI

```bash
proxyctl status                       # egress, exit IP, services, warnings
proxyctl add isp-1 socks5://user:pass@203.0.113.10:1080
proxyctl use isp-1 | test | list | remove isp-1
proxyctl speed [isp-1|direct]         # Mbps down/up, every proxy and the VPS if no name
proxyctl egress proxy|direct
proxyctl exit-node on|off
proxyctl set kill-switch|proxy-dns|cliproxyapi|firewall on|off
proxyctl ports
proxyctl port 8080 tailscale "my app"   # or public / closed; 8080/udp for UDP
proxyctl port remove 8080
proxyctl forwarding                     # check IP forwarding, enable it (persistently) if off
proxyctl secret
```

If exit-node devices can't load anything, check `proxyctl status`. The usual causes are forwarding
being off or the proxy not answering.

## How it works

- `/etc/mihomo/state.json` holds everything: secret, proxies, egress, features, port rules,
  CLIProxyAPI keys. mihomo's `config.yaml` is generated from it plus `/etc/mihomo/base.yaml`.
- `proxyctl apply` makes the system match it. It runs at boot (`proxyctl-apply.service`) and after
  every change. Its rules live in its own chains (`mangle PM-INPUT`, `mangle PM-FWD`) plus `ip rule`
  priority 100 / table 100, so they don't fight Tailscale, Docker or ufw.
- Adding or removing a proxy restarts mihomo, so connections drop for a second. Switching proxies
  doesn't.
- The panel, the mihomo UI (`:9090/ui`) and CLIProxyAPI are plain HTTP. With the default port rules
  they're only reachable over Tailscale, which is WireGuard-encrypted.

## Verify from an exit-node client

- ipinfo.io -> the proxy IP, ISP type, not hosting
- browserleaks.com/webrtc -> no VPS IP
- dnsleaktest.com -> no resolver in the VPS's datacenter
- browserleaks.com/ip -> no IPv6

## Notes

- **UDP**: if your proxy has no SOCKS5 UDP, UDP fails (QUIC falls back to TCP, WebRTC calls won't connect). It never leaks.
- Undo everything: `proxyctl exit-node off`, `proxyctl set firewall off`,
  `systemctl disable --now proxyctl-web mihomo proxyctl-apply`, `cd /opt/CLIProxyAPI && docker compose down`.
