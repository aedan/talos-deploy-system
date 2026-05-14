#!/usr/bin/env bash
set -euo pipefail

IP_BIN="$(command -v ip || true)"

if [ -z "$IP_BIN" ]; then
  echo "iproute2 is required to reconcile deployer Talos node routes" >&2
  exit 1
fi

CIDR="$1"
INTERFACE="$2"
SYSTEMD="$3"

if [ -n "$SYSTEMD" ] && command -v systemctl >/dev/null 2>&1; then
  cat > /tmp/tds-node-routes.service <<EOF
[Unit]
Description=TDS Talos node management host routes
After=network-online.target tds-registry-address.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${IP_BIN} route replace ${CIDR}/32 dev ${INTERFACE}
ExecStop=-${IP_BIN} route del ${CIDR}/32 dev ${INTERFACE}

[Install]
WantedBy=multi-user.target
EOF

  sudo mv /tmp/tds-node-routes.service /etc/systemd/system/tds-node-routes.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now tds-node-routes.service
fi

sudo "$IP_BIN" route replace "${CIDR}/32" dev "${INTERFACE}"
echo "Route ${CIDR}/32 via ${INTERFACE} configured"
