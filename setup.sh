#!/usr/bin/env bash
# VPS setup: CLIProxyAPI + Tailscale + mihomo with switchable ISP proxies, managed from the proxyctl panel.
# Defaults: CLIProxyAPI installed and sent through the proxy, exit node off, firewall rules on.
# Tested target: Ubuntu 22.04 / 24.04, run as root:  sudo bash setup.sh [--no-cliproxyapi] [--derp]
#   --derp: also run Tailscale's relay (derper) on 443/tcp, for networks that block Tailscale's direct UDP
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash setup.sh"; exit 1; }
cd "$(dirname "$0")"
for f in mihomo-base.yaml proxyctl panel.html; do
  [ -f "$f" ] || { echo "$f not found next to setup.sh"; exit 1; }
done
sed -i 's/\r$//' mihomo-base.yaml proxyctl 2>/dev/null || true   # strip Windows line endings

CLIPROXYAPI=1
DERP=0
[ -f /etc/systemd/system/derper.service ] && DERP=1   # once installed, re-runs keep it set up
for arg in "$@"; do
  case "$arg" in
    --no-cliproxyapi) CLIPROXYAPI=0 ;;
    --derp) DERP=1 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Installing packages"
apt-get update -y
apt-get install -y curl gzip unzip tar git iptables iproute2 python3 ca-certificates

echo "==> Tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
# IP forwarding is turned on when you enable the exit node (proxyctl appends to this file).
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
curl -fsSL "$URL" | gunzip > /usr/local/bin/mihomo.new
chmod +x /usr/local/bin/mihomo.new
mv /usr/local/bin/mihomo.new /usr/local/bin/mihomo
/usr/local/bin/mihomo -v

echo "==> mihomo UI (metacubexd)"
mkdir -p /etc/mihomo/ui
# Non-fatal: if this download fails, mihomo fetches the UI itself on first start.
if [ ! -f /etc/mihomo/ui/index.html ]; then
  TMP=$(mktemp -d)
  if curl -fsSL -o "$TMP/ui.zip" https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip \
     && unzip -q "$TMP/ui.zip" -d "$TMP/zip"; then
    cp -r "$TMP"/zip/*/. /etc/mihomo/ui/
  else
    echo "    UI download failed, mihomo will download it on first start"
  fi
  rm -rf "$TMP"
fi

echo "==> proxyctl"
install -m 644 mihomo-base.yaml /etc/mihomo/base.yaml
install -m 755 proxyctl /usr/local/bin/proxyctl
install -D -m 644 panel.html /usr/local/share/proxyctl/panel.html
# Creates the panel secret on first run (kept on re-runs) and writes mihomo's config.yaml.
# No proxies yet: the PROXY group is just REJECT until you add some.
proxyctl init
[ "$CLIPROXYAPI" = 1 ] || proxyctl set cliproxyapi off >/dev/null 2>&1 || true

# Older versions used a separate kill-switch service with rules straight in INPUT/FORWARD.
# proxyctl now keeps all of that in its own chains, so remove the old pieces.
if [ -f /etc/systemd/system/exitnode-killswitch.service ]; then
  echo "==> Removing the old exitnode-killswitch service"
  systemctl disable --now exitnode-killswitch.service 2>/dev/null || true
  rm -f /etc/systemd/system/exitnode-killswitch.service /usr/local/sbin/exitnode-killswitch.sh
  for P in 9090 9091; do
    while iptables  -D INPUT -p tcp --dport $P ! -i tailscale0 -j DROP 2>/dev/null; do :; done
    while ip6tables -D INPUT -p tcp --dport $P ! -i tailscale0 -j DROP 2>/dev/null; do :; done
  done
  WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
  [ -n "$WAN_IF" ] && while iptables -t mangle -D FORWARD -i tailscale0 -o "$WAN_IF" -j DROP 2>/dev/null; do :; done
  while ip6tables -t mangle -D FORWARD -i tailscale0 -j DROP 2>/dev/null; do :; done
fi

echo "==> Services"
cat >/usr/local/sbin/mihomo-tun-route.sh <<'EOF'
#!/usr/bin/env bash
# Point table 100 at tun0 once mihomo has created it. When mihomo stops,
# tun0 disappears, this route goes with it and the kill switch's blackhole takes over.
for i in $(seq 1 30); do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; done
ip route replace default dev tun0 table 100 metric 100
EOF
chmod +x /usr/local/sbin/mihomo-tun-route.sh

cat >/etc/systemd/system/proxyctl-apply.service <<'EOF'
[Unit]
Description=proxyctl: firewall, exit-node routing and kill switch from /etc/mihomo/state.json
After=network-online.target
Wants=network-online.target
Before=tailscaled.service mihomo.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/proxyctl apply --boot

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=mihomo proxy core (egress through the selected proxy)
After=network-online.target proxyctl-apply.service
Wants=network-online.target
Requires=proxyctl-apply.service

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
Description=proxyctl web panel, port 9091
After=mihomo.service tailscaled.service docker.service

[Service]
# Re-apply once Docker is up: it resets the FORWARD chain the exit node needs.
ExecStartPre=-/usr/local/bin/proxyctl apply --boot
ExecStart=/usr/local/bin/proxyctl serve
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable proxyctl-apply.service mihomo.service proxyctl-web.service
systemctl restart proxyctl-apply.service
systemctl restart mihomo.service proxyctl-web.service

if [ "$CLIPROXYAPI" = 1 ]; then
  echo "==> CLIProxyAPI (Docker, host network)"
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  [ -d /opt/CLIProxyAPI/.git ] || git clone --depth 1 https://github.com/router-for-me/CLIProxyAPI.git /opt/CLIProxyAPI
  # config.yaml with generated management + API keys (only if missing), plus a host-network override
  proxyctl init-cliproxyapi
fi

echo "==> Tailscale login"
tailscale status >/dev/null 2>&1 || tailscale up

if [ "$DERP" = 1 ]; then
  echo "==> DERP relay (derper on 443/tcp, STUN on 3478/udp)"
  # Clients reach it over HTTPS to this VPS's IP. No domain needed: derper makes a self-signed
  # certificate for the IP, and the tailnet's derpMap pins it (proxyctl derp prints that snippet).
  DERP_HOST=${DERP_HOST:-$(curl -4 -fsS https://api.ipify.org || true)}
  [ -n "$DERP_HOST" ] || { echo "Could not detect this VPS's public IPv4, re-run with DERP_HOST=1.2.3.4"; exit 1; }
  USED=$(ss -Hltnp 'sport = :443' | grep -v derper || true)
  [ -z "$USED" ] || { echo "Port 443/tcp is already used by something else:"; echo "$USED"; exit 1; }
  if [ ! -x /usr/local/bin/derper ]; then
    case "$(uname -m)" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; esac
    GOVER=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)
    TMP=$(mktemp -d)
    echo "    building derper with $GOVER, this takes a few minutes"
    curl -fsSL "https://go.dev/dl/${GOVER}.linux-${GOARCH}.tar.gz" | tar -xz -C "$TMP"
    GOPATH="$TMP/gopath" GOCACHE="$TMP/cache" GOBIN=/usr/local/bin GOTOOLCHAIN=auto \
      "$TMP/go/bin/go" install tailscale.com/cmd/derper@latest
    rm -rf "$TMP"
  fi
  mkdir -p /var/lib/derper
  cat >/etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay for this tailnet, https://${DERP_HOST}:443
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
# -verify-clients: only nodes of this VPS's own tailnet may relay through it
ExecStart=/usr/local/bin/derper -hostname ${DERP_HOST} -a :443 -http-port -1 -stun-port 3478 -certmode manual -certdir /var/lib/derper -verify-clients
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable derper.service
  systemctl restart derper.service
  for i in $(seq 1 20); do [ -f "/var/lib/derper/${DERP_HOST}.crt" ] && break; sleep 1; done
  # proxyctl's rules only ever restrict ports; an active ufw has to let them in as well
  proxyctl port 443 public "DERP relay" >/dev/null
  proxyctl port 3478/udp public "DERP STUN" >/dev/null
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 443/tcp >/dev/null
    ufw allow 3478/udp >/dev/null
  fi
fi

echo "==> Applying settings"
# firewall, routing, DNS, exit-node advertisement and CLIProxyAPI's proxy-url, all from state.json
proxyctl apply
if [ "$CLIPROXYAPI" = 1 ]; then
  (cd /opt/CLIProxyAPI && docker compose up -d)
fi

TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
cat <<EOF

Done. Open the panel from a device on your tailnet:
  http://${TS_IP:-<vps-tailscale-ip>}:9091      secret: $(proxyctl secret)

Next: add a proxy on the Proxies page (or: proxyctl add isp-1 socks5://user:pass@host:port).
Until then CLIProxyAPI's requests are blocked, never sent from this VPS's own IP.
Prefer the VPS's own IP? Settings -> Egress -> Direct (or: proxyctl egress direct).
EOF
[ "$CLIPROXYAPI" = 1 ] && echo "CLIProxyAPI: http://${TS_IP:-<vps-tailscale-ip>}:8317/v1 (API key and management key are in the panel)"
[ "$DERP" = 1 ] && echo "DERP relay: paste the snippet from 'sudo proxyctl derp' (also in the panel's Settings) into the Tailscale admin console -> Access controls"
exit 0
