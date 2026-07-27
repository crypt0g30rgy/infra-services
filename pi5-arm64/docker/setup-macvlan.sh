# docker network rm pihole_macvlan
# docker network create --driver macvlan --subnet=192.168.1.0/24 --gateway=192.168.1.1 -o parent=eth0  pihole_macvlan

#!/usr/bin/env bash
#
# setup-macvlan.sh
#
# Creates a Docker macvlan network and a "shim" interface on the host so the
# host itself can reach containers on that macvlan network (macvlan networks
# normally isolate the host from the containers).
#
# Usage:
#   sudo ./setup-macvlan.sh
#   sudo ./setup-macvlan.sh --install-service   # also install+enable systemd unit
#   sudo ./setup-macvlan.sh --uninstall         # tear everything down
#
set -euo pipefail

# ---- Config (edit as needed) ------------------------------------------------
PARENT_IF="eth0"
SHIM_IF="macvlan-shim"
DOCKER_NET="macvlan_net"
SUBNET="192.168.1.0/24"
GATEWAY="192.168.1.1"
IP_RANGE="192.168.1.96/28" # covers 192.168.1.96-192.168.1.111. 16 total addresses, 14 usable (excluding network/broadcast)
HOST_IP="192.168.1.223"
SERVICE_FILE="/etc/systemd/system/macvlan-shim.service"
# -----------------------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

create_docker_network() {
  if docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
    echo "Docker network '$DOCKER_NET' already exists, skipping."
    return
  fi
  echo "Creating Docker macvlan network '$DOCKER_NET'..."
  docker network create -d macvlan \
    --subnet="$SUBNET" \
    --gateway="$GATEWAY" \
    --ip-range="$IP_RANGE" \
    --aux-address "host=$HOST_IP" \
    -o parent="$PARENT_IF" \
    "$DOCKER_NET"
}

create_shim_interface() {
  if ip link show "$SHIM_IF" >/dev/null 2>&1; then
    echo "Shim interface '$SHIM_IF' already exists, skipping."
    return
  fi
  echo "Creating shim interface '$SHIM_IF'..."
  ip link add link "$PARENT_IF" name "$SHIM_IF" type macvlan mode bridge
  ip addr add "${HOST_IP}/32" dev "$SHIM_IF"
  ip link set "$SHIM_IF" up
  ip route add "$IP_RANGE" dev "$SHIM_IF" 2>/dev/null || true
}

install_systemd_service() {
  echo "Installing systemd service at $SERVICE_FILE..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Macvlan Shim Interface
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "\\
  ip link add link ${PARENT_IF} name ${SHIM_IF} type macvlan mode bridge && \\
  ip addr add ${HOST_IP}/32 dev ${SHIM_IF} && \\
  ip link set ${SHIM_IF} up && \\
  ip route add ${IP_RANGE} dev ${SHIM_IF}"
ExecStop=/bin/bash -c "ip link del ${SHIM_IF}"

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now macvlan-shim
  echo "Service installed and started."
}

uninstall_all() {
  echo "Tearing down..."
  systemctl disable --now macvlan-shim 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  ip link del "$SHIM_IF" 2>/dev/null || true
  docker network rm "$DOCKER_NET" 2>/dev/null || true
  echo "Done."
}

main() {
  require_root

  case "${1:-}" in
    --uninstall)
      uninstall_all
      ;;
    --install-service)
      create_docker_network
      install_systemd_service
      ;;
    "")
      create_docker_network
      create_shim_interface
      echo
      echo "Done. To persist the shim interface across reboots, re-run with:"
      echo "  sudo $0 --install-service"
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--install-service|--uninstall]" >&2
      exit 1
      ;;
  esac
}

main "$@"