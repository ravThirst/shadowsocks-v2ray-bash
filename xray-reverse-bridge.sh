#!/bin/bash
set -euo pipefail

# Xray reverse proxy - BRIDGE side (the exit server that CAN reach the portal).
# Dials out to the portal over VLESS+WS+TLS and sends the traffic it receives
# back through that connection out to the internet. No inbound ports needed.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

# --- Interactive Inputs ---
read -rp "Enter portal domain (TLS SNI): " PORTAL_HOST
read -rp "Enter portal IP address [resolve domain]: " PORTAL_IP
PORTAL_IP=${PORTAL_IP:-$PORTAL_HOST}
read -rp "Enter portal port [443]: " PORTAL_PORT
PORTAL_PORT=${PORTAL_PORT:-443}
read -rp "Enter VLESS UUID: " UUID
read -rp "Enter WebSocket path: " WS_PATH

[[ -z "$PORTAL_HOST" || -z "$UUID" || -z "$WS_PATH" ]] && error "Domain, UUID and WS path are required"
[[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"

# --- Dependencies ---
info "Installing dependencies..."
apt update -qq
apt install -y curl

# --- Xray ---
info "Installing Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# --- Xray Config ---
info "Writing Xray configuration..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "reverse": {
    "bridges": [ { "tag": "bridge", "domain": "reverse.internal" } ]
  },
  "outbounds": [
    {
      "tag": "tunnel",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${PORTAL_IP}",
            "port": ${PORTAL_PORT},
            "users": [ { "id": "${UUID}", "encryption": "none" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${PORTAL_HOST}",
          "alpn": ["http/1.1"],
          "fingerprint": "chrome"
        },
        "wsSettings": { "path": "${WS_PATH}", "host": "${PORTAL_HOST}" }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["bridge"], "domain": ["full:reverse.internal"], "outboundTag": "tunnel" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "direct" }
    ]
  }
}
EOF

/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null || error "Xray config test failed"

systemctl enable xray
systemctl restart xray

info "✅ Bridge deployment complete! Connecting to ${PORTAL_HOST}:${PORTAL_PORT}."
info "Check with: journalctl -u xray -f"
