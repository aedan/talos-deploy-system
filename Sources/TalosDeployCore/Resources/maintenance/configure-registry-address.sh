#!/usr/bin/env bash
set -euo pipefail

IP_BIN="$(command -v ip || true)"

if [ -z "$IP_BIN" ]; then
  echo "iproute2 is required to manage deployer registry address" >&2
  exit 1
fi

CIDR="$1"
INTERFACE="$2"
SYSTEMD="$3"

for existing_dev in $("${IP_BIN}" -o addr show | awk '$4 == "${CIDR}" { print $2 }'); do
  if [ "$existing_dev" != "$INTERFACE" ]; then
    sudo "$IP_BIN" addr del "$CIDR" dev "$existing_dev" 2>/dev/null || true
  fi
done

sudo "$IP_BIN" addr replace "$CIDR" dev "$INTERFACE"

if [ -n "$SYSTEMD" ] && command -v systemctl >/dev/null 2>&1; then
  cat > /tmp/tds-registry-address.service <<EOF
[Unit]
Description=TDS node-facing registry address
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${IP_BIN} addr replace ${CIDR} dev ${INTERFACE}
ExecStop=${IP_BIN} addr del ${CIDR} dev ${INTERFACE}

[Install]
WantedBy=multi-user.target
EOF

  sudo mv /tmp/tds-registry-address.service /etc/systemd/system/tds-registry-address.service
  sudo systemctl daemon-reload
  sudo systemctl enable tds-registry-address.service
  sudo systemctl restart tds-registry-address.service
fi

echo "Registry address ${CIDR} configured on interface ${INTERFACE}"
