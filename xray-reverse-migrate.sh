#!/bin/bash
set -euo pipefail

# Migrate a server set up by ss-v2ray-client.sh to an Xray reverse PORTAL.
# Keeps the existing ipset (proxy_targets), /etc/proxy-ips.txt, update-proxy-ips.sh,
# REDSOCKS iptables chains and tproxy-routing.service; Xray simply takes over the
# local redirect port that ss-redir used, and ss-redir is disabled.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

# --- Detect Existing Client Setup ---
SS_CONFIG="/etc/shadowsocks-libev/ss-redir.json"
[[ -f "$SS_CONFIG" ]] || error "$SS_CONFIG not found, run xray-reverse-portal.sh for a fresh setup"
ipset list proxy_targets >/dev/null 2>&1 || error "ipset 'proxy_targets' not found, is the client setup complete?"
iptables -t nat -S REDSOCKS >/dev/null 2>&1 || error "iptables chain 'REDSOCKS' not found, is the client setup complete?"

LOCAL_PORT=$(sed -nE 's/.*"local_port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$SS_CONFIG")
[[ -z "$LOCAL_PORT" ]] && error "Could not read local_port from $SS_CONFIG"
info "Found ss-redir client on local port $LOCAL_PORT, Xray will take it over"

# --- Interactive Inputs ---
read -rp "Enter domain name pointing to THIS server (e.g., rv.domain.com): " HOST
read -rp "Enter ACME email: " ACME_EMAIL
read -rp "Enter VLESS UUID [generate]: " UUID
read -rp "Enter WebSocket path [random]: " WS_PATH
read -rp "Enter TLS listen port [443]: " LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-443}

[[ -z "$HOST" || -z "$ACME_EMAIL" ]] && error "Domain and Email are required"
[[ -z "$WS_PATH" ]] && WS_PATH="/$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
[[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"

# --- Certificate Validation Method ---
echo -e "\n${CYAN}Select Certificate Validation Method:${NC}"
echo "  1) Cloudflare DNS-01"
echo "  2) TLS-ALPN-01 (port 443 must be free during issue/renew)"
read -rp "Enter choice [1/2]: " DNS_CHOICE

if [[ "$DNS_CHOICE" == "1" ]]; then
    read -rp "Enter Cloudflare API Token: " CF_TOKEN
    [[ -z "$CF_TOKEN" ]] && error "Cloudflare API Token is required for DNS-01"
    read -rp "Enter Cloudflare Zone ID (optional, needed for zone-scoped tokens): " CF_ZONE_ID
    export CF_Token="$CF_TOKEN"
    [[ -n "$CF_ZONE_ID" ]] && export CF_Zone_ID="$CF_ZONE_ID"
    ACME_MODE=(--dns dns_cf)
elif [[ "$DNS_CHOICE" == "2" ]]; then
    # hooks are saved by acme.sh and reused on automatic renewals
    ACME_MODE=(--alpn --pre-hook "systemctl stop xray || true" --post-hook "systemctl start xray || true")
else
    error "Invalid choice. Please enter 1 or 2."
fi

# --- Missing Dependencies Only ---
# ipset-persistent restores proxy_targets on boot, before the saved iptables rules that reference it
info "Installing missing dependencies..."
apt update -qq
apt install -y curl socat cron ipset-persistent
systemctl enable --now cron

# --- Xray ---
if [[ ! -x /usr/local/bin/xray ]]; then
    info "Installing Xray..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
[[ -z "$UUID" ]] && UUID=$(/usr/local/bin/xray uuid)

# --- ACME.sh & Certificate ---
if [[ ! -d /root/.acme.sh ]]; then
    info "Installing acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
fi

CERT_DIR="/usr/local/etc/xray/certs"
mkdir -p "$CERT_DIR"

info "Issuing certificate for $HOST..."
systemctl stop xray 2>/dev/null || true
/root/.acme.sh/acme.sh --issue "${ACME_MODE[@]}" -d "$HOST" \
    --server letsencrypt || [[ $? -eq 2 ]]   # 2 = cert still valid, skipped

/root/.acme.sh/acme.sh --install-cert -d "$HOST" --ecc \
    --fullchain-file "$CERT_DIR/cert.pem" \
    --key-file "$CERT_DIR/key.pem" \
    --reloadcmd "chmod 644 $CERT_DIR/*.pem; systemctl restart xray"

chmod 644 "$CERT_DIR"/*.pem   # xray service runs as nobody

# --- Xray Config ---
info "Writing Xray configuration..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "tunnel-in",
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "email": "bridge", "reverse": { "tag": "bridge-out" } } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            { "certificateFile": "${CERT_DIR}/cert.pem", "keyFile": "${CERT_DIR}/key.pem" }
          ]
        },
        "wsSettings": { "path": "${WS_PATH}" }
      }
    },
    {
      "tag": "redir-tcp",
      "listen": "0.0.0.0",
      "port": ${LOCAL_PORT},
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "redirect" } }
    },
    {
      "tag": "redir-udp",
      "listen": "0.0.0.0",
      "port": ${LOCAL_PORT},
      "protocol": "dokodemo-door",
      "settings": { "network": "udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
    }
  ],
  "outbounds": [
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["redir-tcp", "redir-udp"], "outboundTag": "bridge-out" },
      { "type": "field", "inboundTag": ["tunnel-in"], "outboundTag": "block" }
    ]
  }
}
EOF

/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null || error "Xray config test failed"

# --- Switch ss-redir -> Xray ---
info "Disabling ss-redir (config kept for rollback)..."
systemctl disable --now ss-redir.service 2>/dev/null || true

netfilter-persistent save
systemctl enable xray
systemctl restart xray

info "✅ Migration complete! VLESS+WS+TLS listening on ${LISTEN_PORT}/TCP, redirect port ${LOCAL_PORT} now served by Xray."
echo -e "${CYAN}Use these values on the bridge (exit) server:${NC}"
echo "  Domain : ${HOST}"
echo "  Port   : ${LISTEN_PORT}"
echo "  UUID   : ${UUID}"
echo "  WS path: ${WS_PATH}"
info "Target list is unchanged: /etc/proxy-ips.txt, apply with /usr/local/bin/update-proxy-ips.sh"
echo -e "${CYAN}Rollback:${NC} systemctl disable --now xray && systemctl enable --now ss-redir"
