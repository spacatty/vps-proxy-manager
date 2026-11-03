# vps-proxy-manager

Turn any cheap VPS into a Tailscale exit node whose traffic leaves through a
static ISP (residential-class) SOCKS5/HTTP proxy, with a web panel and CLI to
add, switch and test proxies and to turn routing on and off.

```
your devices --(Tailscale)--> VPS exit node --> mihomo (tun0) --> ISP proxy --> internet
                                   |
                                   +-- kill switch: if mihomo/proxy is down, traffic is dropped,
                                       never sent out via the VPS's datacenter IP
```

## What's in here

| File | What it does |
|---|---|
| `setup.sh` | One-shot install on the VPS: Tailscale, mihomo, metacubexd UI, kill switch, panel |
| `proxyctl` | CLI + web panel (Python, stdlib only): proxies, routing, forwarding, status |
| `mihomo-base.yaml` | mihomo settings (TUN, DNS, sniffer). Proxies and the secret are added by `proxyctl` |

Nothing to edit before installing: no proxies are hardcoded, and the secret is
generated on the first run.

## 1. Install on the VPS

From Windows PowerShell:

```powershell
scp -r C:\Users\user\Desktop\vps-proxy-manager root@YOUR_VPS_IP:/root/
ssh root@YOUR_VPS_IP
```

On the VPS (Ubuntu 22.04/24.04):

```bash
cd /root/vps-proxy-manager
sudo bash setup.sh
```

It logs into Tailscale if needed, prints the panel URL and the secret, and
routes nothing yet.

## 2. Add a proxy and start routing

**Panel** (from any device on your tailnet): `http://<vps-tailscale-ip>:9091`.
Enter the secret, add a proxy, then press **Start routing**.

**Or the CLI** on the VPS:

```bash
proxyctl add isp-1 socks5://user:pass@203.0.113.10:1080
proxyctl add isp-2 203.0.113.20:1080:user:pass   # host:port:user:pass works too
proxyctl routing on
```

`routing on` checks the selected proxy actually reaches the internet first. It
then enables IP forwarding, points the VPS's DNS at mihomo (DoH through the
proxy) and advertises the VPS as an exit node. `routing off` undoes the last two.

First time only: Tailscale admin console -> Machines -> the VPS -> **Edit route
settings** -> tick **Use as exit node**, and **Disable key expiry**. Then pick it
as the exit node on your devices.

## 3. Manage

```bash
proxyctl status          # routing, forwarding, kill switch, selected proxy, exit IP + ISP
proxyctl list
proxyctl use isp-2       # switch + drop old connections
proxyctl use REJECT      # block all exit-node traffic without turning routing off
proxyctl test            # latency per proxy
proxyctl remove isp-1
proxyctl forwarding      # check IP forwarding, enable it (persistently) if off
proxyctl secret          # print the panel secret
```

If devices using the exit node can't load anything, check `proxyctl status`:
forwarding OFF or an unreachable exit IP are the usual causes.

Adding or removing a proxy restarts mihomo (connections drop for a second).
Switching does not.

Live connections and logs: the mihomo UI at `http://<vps-tailscale-ip>:9090/ui`,
backend `http://<vps-tailscale-ip>:9090`, same secret.

State lives in `/etc/mihomo/state.json` (secret, proxies, routing).
`/etc/mihomo/config.yaml` is generated from it plus `/etc/mihomo/base.yaml`,
so edit the base, not the generated file.

## 4. Verify from a client (exit node on)

- ipinfo.io -> the proxy IP, ISP type, not hosting
- browserleaks.com/webrtc -> no VPS IP
- dnsleaktest.com -> no resolver in the VPS's datacenter
- browserleaks.com/ip -> no IPv6

## Notes

- **UDP**: if your proxy has no SOCKS5 UDP, UDP fails (QUIC falls back to TCP, WebRTC calls won't connect). It never leaks.
- **VPS DNS** goes through mihomo while routing is on. If mihomo is down or REJECT is selected, the VPS itself can't resolve names (apt etc.): `proxyctl routing off` gives it normal DNS back.
- The panel and the mihomo UI are plain HTTP, but only reachable over Tailscale (WireGuard-encrypted). Ports 9090/9091 are blocked on the public interface.
- Undo everything: `proxyctl routing off`, `systemctl disable --now proxyctl-web mihomo exitnode-killswitch`, `ip rule del priority 100`.
