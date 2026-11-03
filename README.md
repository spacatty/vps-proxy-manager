# vps-proxy-manager

Turn any cheap VPS into a Tailscale exit node whose traffic leaves through a
static ISP (residential-class) SOCKS5 proxy, with a web UI to switch proxies.

```
your devices --(Tailscale)--> VPS exit node --> mihomo (tun0) --> ISP proxy --> internet
                                   |
                                   +-- kill switch: if mihomo/proxy is down, traffic is dropped,
                                       never sent out via the VPS's datacenter IP
```

## What's in here

| File | What it does |
|---|---|
| `config.yaml` | mihomo config: your proxies, the selector group, DNS-over-proxy, web UI |
| `setup.sh` | One-shot install on the VPS: Tailscale, mihomo, metacubexd UI, kill switch, DNS |
| `proxyctl` | CLI on the VPS: `status`, `list`, `use NAME`, `test` |

## 1. Edit `config.yaml`

- `secret:` replace `CHANGE-ME` with a long random string (it's the UI password).
- `proxies:` your SOCKS5 ISP proxies (IP, port, user, pass). Use simple names, no spaces.
- `proxy-groups -> PROXY -> proxies:` list the same names.

Don't add `DIRECT` to the group, that's what keeps the datacenter IP from ever being used.

## 2. Copy to the VPS and run

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

The script stops before touching DNS if the proxy doesn't work, so a typo in
the proxy details won't cut the VPS off from the internet.

## 3. Finish in Tailscale

Admin console -> Machines -> the VPS -> **Edit route settings** -> tick
**Use as exit node**, and **Disable key expiry**. Then pick it as the exit node
on your devices.

## 4. Manage

**Web UI** (from any device on your tailnet): `http://<vps-tailscale-ip>:9090/ui`
Backend URL `http://<vps-tailscale-ip>:9090`, secret from `config.yaml`.
Switch proxies, run latency tests, see live connections and logs.

**CLI** on the VPS:

```bash
proxyctl status      # service, kill switch, selected proxy, exit IP + ISP
proxyctl list
proxyctl use isp-2   # switch + drop old connections
proxyctl test        # latency per proxy
proxyctl forwarding  # check IP forwarding, enable it (persistently) if off
```

If devices using the exit node can't load anything, run `proxyctl forwarding`
first. IP forwarding being off is the most common cause.

Adding or changing proxies: edit `/etc/mihomo/config.yaml`, then `systemctl restart mihomo`.

## 5. Verify from a client (exit node on)

- ipinfo.io -> the proxy IP, ISP type, not hosting
- browserleaks.com/webrtc -> no VPS IP
- dnsleaktest.com -> no resolver in the VPS's datacenter
- browserleaks.com/ip -> no IPv6

## Notes

- **UDP**: if your proxy has no SOCKS5 UDP, UDP fails (QUIC falls back to TCP, WebRTC calls won't connect). It never leaks.
- **VPS DNS** now goes through mihomo too. If mihomo is down, the VPS itself can't resolve names (apt etc.) until it's back: `systemctl restart mihomo`.
- The UI is plain HTTP, but only reachable over Tailscale (WireGuard-encrypted); port 9090 is blocked on the public interface.
- Undo: `systemctl disable --now mihomo exitnode-killswitch`, `ip rule del priority 100`, `systemctl enable --now systemd-resolved`, `ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf`.
