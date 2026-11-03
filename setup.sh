#!/usr/bin/env bash
# VPS setup: Tailscale exit node -> mihomo TUN -> switchable SOCKS5 ISP proxies.
# Kill switch: traffic from Tailscale clients can never leave via the VPS's own IP.
# Tested target: Ubuntu 22.04 / 24.04, run as root:  sudo bash setup.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash setup.sh"; exit 1; }
cd "$(dirname "$0")"
[ -f mihomo-base.yaml ] || { echo "mihomo-base.yaml not found next to setup.sh"; exit 1; }
sed -i 's/\r$//' mihomo-base.yaml proxyctl 2>/dev/null || true   # strip Windows line endings

WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
[ -n "$WAN_IF" ] || { echo "Could not detect the WAN interface"; exit 1; }
echo "==> WAN interface: $WAN_IF"

echo "==> Installing packages"
apt-get update -y
apt-get install -y curl gzip unzip tar iptables iproute2 python3 ca-certificates

echo "==> Tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
# IP forwarding is turned on by `proxyctl routing on` (it appends to this file).
grep -qs 'rp_filter' /etc/sysctl.d/99-exit-node.conf || cat >>/etc/sysctl.d/99-exit-node.conf <<'EOF'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
sysctl --system >/dev/null

echo "==> mihomo"
case "$(uname -m)" in
  x86_64)  PAT="mihomo-linux-amd64-compatible-v[0-9.]+\.gz" ;;
  aarch64) PAT="mihomo-linux-arm64-v[0-9.]+\.gz" ;;
  *) echo "Unsupported CPU: $(uname -m)"; exit 1 ;;
esac
URL=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
      | grep -oE "https://[^\"]*/${PAT}" | head -n1)
[ -n "$URL" ] || { echo "Could not find a mihomo release"; exit 1; }
curl -fsSL "$URL" | gunzip > /usr/local/bin/mihomo
chmod +x /usr/local/bin/mihomo
/usr/local/bin/mihomo -v

mkdir -p /etc/mihomo/ui
install -m 644 mihomo-base.yaml /etc/mihomo/base.yaml
install -m 755 proxyctl /usr/local/bin/proxyctl
# Creates the panel/API secret on first run (kept on re-runs) and writes config.yaml.
# No proxies yet: the PROXY group is just REJECT until you add some.
proxyctl init

echo "==> Web UI (metacubexd)"
# Non-fatal: if this download fails, mihomo fetches the UI itself on first start.
if [ ! -f /etc/mihomo/ui/index.html ]; then
  TMP=$(mktemp -d)
  if curl -fsSL -o "$TMP/ui.zip" https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip \
     && unzip -q "$TMP/ui.zip" -d "$TMP/zip"; then
    cp -r "$TMP"/zip/*/. /etc/mihomo/ui/
  else
    echo "    UI download failed, mihomo will download it on first start"
    rmdir /etc/mihomo/ui 2>/dev/null || true
  fi
  rm -rf "$TMP"
fi

echo "==> Kill switch + routing"
cat >/usr/local/sbin/exitnode-killswitch.sh <<EOF
#!/usr/bin/env bash
# Everything arriving from Tailscale goes to table 100: tun0 (mihomo) or blackhole.
ip rule del priority 100 2>/dev/null || true
ip rule add iif tailscale0 lookup 100 priority 100
ip route replace blackhole default table 100 metric 500
ip route replace throw 100.64.0.0/10 table 100
# Second layer: never forward Tailscale traffic straight out of the WAN NIC.
iptables  -t mangle -C FORWARD -i tailscale0 -o $WAN_IF -j DROP 2>/dev/null || iptables  -t mangle -I FORWARD 1 -i tailscale0 -o $WAN_IF -j DROP
ip6tables -t mangle -C FORWARD -i tailscale0 -j DROP 2>/dev/null           || ip6tables -t mangle -I FORWARD 1 -i tailscale0 -j DROP
# mihomo UI/API (9090) and the proxyctl panel (9091) only reachable over Tailscale.
for PORT in 9090 9091; do
  iptables  -C INPUT -p tcp --dport \$PORT ! -i tailscale0 -j DROP 2>/dev/null || iptables  -I INPUT 1 -p tcp --dport \$PORT ! -i tailscale0 -j DROP
  ip6tables -C INPUT -p tcp --dport \$PORT ! -i tailscale0 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -p tcp --dport \$PORT ! -i tailscale0 -j DROP
done
exit 0
EOF
chmod +x /usr/local/sbin/exitnode-killswitch.sh

cat >/usr/local/sbin/mihomo-tun-route.sh <<'EOF'
#!/usr/bin/env bash
# Point table 100 at tun0 once mihomo has created it. When mihomo stops,
# tun0 disappears, this route goes with it and the blackhole takes over.
for i in $(seq 1 30); do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; done
ip route replace default dev tun0 table 100 metric 100
EOF
chmod +x /usr/local/sbin/mihomo-tun-route.sh

cat >/etc/systemd/system/exitnode-killswitch.service <<'EOF'
[Unit]
Description=Exit-node kill switch (no forwarding via the datacenter IP)
After=network-pre.target
Wants=network-pre.target
Before=tailscaled.service mihomo.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/exitnode-killswitch.sh

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=mihomo proxy core (exit node -> SOCKS5)
After=network-online.target exitnode-killswitch.service
Wants=network-online.target
Requires=exitnode-killswitch.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecStartPost=/usr/local/sbin/mihomo-tun-route.sh
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/proxyctl-web.service <<'EOF'
[Unit]
Description=proxyctl web panel (proxies + routing), port 9091, Tailscale only
After=mihomo.service

[Service]
ExecStart=/usr/local/bin/proxyctl serve
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now exitnode-killswitch.service
systemctl enable mihomo.service proxyctl-web.service
systemctl restart mihomo.service proxyctl-web.service

echo "==> Tailscale login"
# Not advertised as an exit node yet: that's `proxyctl routing on`, once a proxy works.
tailscale status >/dev/null 2>&1 || tailscale up

TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
cat <<EOF

Done. Nothing is routed yet. Next:
  1. Open the panel from a device on your tailnet: http://${TS_IP:-<vps-tailscale-ip>}:9091
     Secret: $(proxyctl secret)
  2. Add a proxy there (or: proxyctl add isp-1 socks5://user:pass@host:port), then "Start routing"
     (or: proxyctl routing on). It checks the proxy works before turning anything on.
  3. First time only: Tailscale admin console -> Machines -> this VPS -> Edit route settings ->
     tick "Use as exit node", and "Disable key expiry".
  Live connections/logs: http://${TS_IP:-<vps-tailscale-ip>}:9090/ui (same secret)
EOF
