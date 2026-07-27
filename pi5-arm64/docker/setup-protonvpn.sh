#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo."; exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl disable --now proton-vpn-rotate.timer 2>/dev/null || true
  systemctl disable --now vpn.service 2>/dev/null || true
  rm -f /etc/systemd/system/vpn.service \
        /etc/systemd/system/proton-vpn-rotate.service \
        /etc/systemd/system/proton-vpn-rotate.timer
  systemctl daemon-reload
  rm -f /usr/local/bin/proton-vpn-rotate.sh
  rm -rf /etc/openvpn/protonvpn
  rm -f /var/lib/protonvpn-rotation.state
  apt -y remove openvpn || true
  apt -y autoremove || true
  echo "Uninstalled."
  exit 0
fi

if [[ $# -ne 2 ]]; then
  echo "Usage:"
  echo "  sudo $0 <config-dir> <vpn-creds.txt>"
  echo "  sudo $0 --uninstall"
  exit 1
fi

CFGSRC=$(realpath "$1")
CREDS=$(realpath "$2")

apt update
apt install -y openvpn

install -d /etc/openvpn/protonvpn
cp "$CFGSRC"/*.ovpn /etc/openvpn/protonvpn/
cp "$CREDS" /etc/openvpn/protonvpn/credentials
chmod 600 /etc/openvpn/protonvpn/credentials

find /etc/openvpn/protonvpn -name "*.ovpn" \
 -exec sed -i 's|^auth-user-pass$|auth-user-pass /etc/openvpn/protonvpn/credentials|' {} \;

FIRST=$(find /etc/openvpn/protonvpn -name "*.ovpn"|sort|head -1)
ln -sfn "$FIRST" /etc/openvpn/protonvpn/current.ovpn

cat >/etc/systemd/system/vpn.service <<'EOF'
[Unit]
Description=ProtonVPN OpenVPN
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/protonvpn/current.ovpn
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

cat >/usr/local/bin/proton-vpn-rotate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VPNDIR=/etc/openvpn/protonvpn
STATE=/var/lib/protonvpn-rotation.state
mkdir -p /var/lib
mapfile -t FILES < <(find "$VPNDIR" -maxdepth 1 -name "*.ovpn" ! -name current.ovpn | sort)
[[ ${#FILES[@]} -gt 0 ]]
IDX=0
[[ -f "$STATE" ]] && IDX=$(cat "$STATE")
NEXT=$(((IDX+1)%${#FILES[@]}))
echo "$NEXT" >"$STATE"
ln -sfn "${FILES[$NEXT]}" "$VPNDIR/current.ovpn"
systemctl restart vpn.service
EOF
chmod +x /usr/local/bin/proton-vpn-rotate.sh

cat >/etc/systemd/system/proton-vpn-rotate.service <<'EOF'
[Unit]
Description=Rotate ProtonVPN
[Service]
Type=oneshot
ExecStart=/usr/local/bin/proton-vpn-rotate.sh
EOF

cat >/etc/systemd/system/proton-vpn-rotate.timer <<'EOF'
[Unit]
Description=Rotate ProtonVPN every 6 hours
[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vpn.service
systemctl enable --now proton-vpn-rotate.timer

echo "Installed successfully."
echo "Rotate now: systemctl start proton-vpn-rotate.service"
