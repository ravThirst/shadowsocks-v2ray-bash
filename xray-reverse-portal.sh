#!/bin/bash
set -euo pipefail

# Xray reverse proxy - PORTAL side (the box that can NOT reach the exit server).
# Listens for VLESS+WS+TLS on a real domain; the bridge (exit server) dials in,
# and traffic for IPs in /etc/reverse-ips.txt is sent back through that connection.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

# --- Interactive Inputs ---
read -rp "Enter domain name pointing to THIS server (e.g., rv.domain.com): " HOST
read -rp "Enter ACME email: " ACME_EMAIL
read -rp "Enter VLESS UUID [generate]: " UUID
read -rp "Enter WebSocket path [random]: " WS_PATH
read -rp "Enter TLS listen port [443]: " LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-443}
read -rp "Enter local redirect port [12346]: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-12346}

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

# --- System Dependencies ---
info "Installing system dependencies..."
apt update -qq
apt install -y curl socat cron ipset ipset-persistent iptables netfilter-persistent
systemctl enable --now netfilter-persistent cron

# --- Xray ---
info "Installing Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
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
  "reverse": {
    "portals": [ { "tag": "portal", "domain": "reverse.internal" } ]
  },
  "inbounds": [
    {
      "tag": "tunnel-in",
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
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
      { "type": "field", "inboundTag": ["tunnel-in"], "domain": ["full:reverse.internal"], "outboundTag": "portal" },
      { "type": "field", "inboundTag": ["redir-tcp", "redir-udp"], "outboundTag": "portal" },
      { "type": "field", "inboundTag": ["tunnel-in"], "outboundTag": "block" }
    ]
  }
}
EOF

/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null || error "Xray config test failed"

# --- IPSet Management Script ---
IP_LIST="/etc/reverse-ips.txt"
UPDATE_SCRIPT="/usr/local/bin/update-reverse-ips.sh"

[[ ! -f "$IP_LIST" ]] && touch "$IP_LIST"

cat > "$UPDATE_SCRIPT" <<'IPEOF'
#!/bin/bash
IPSET_NAME="reverse_targets"
IP_LIST="/etc/reverse-ips.txt"
ipset create ${IPSET_NAME}_new hash:net -exist
ipset flush ${IPSET_NAME}_new
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    ipset add ${IPSET_NAME}_new "$line" 2>/dev/null || true
done < "$IP_LIST"
if ipset list ${IPSET_NAME} >/dev/null 2>&1; then
    ipset swap ${IPSET_NAME} ${IPSET_NAME}_new
    ipset destroy ${IPSET_NAME}_new
else
    ipset rename ${IPSET_NAME}_new ${IPSET_NAME}
fi
echo "✅ ipset '${IPSET_NAME}' updated."
netfilter-persistent save
IPEOF
chmod +x "$UPDATE_SCRIPT"

"$UPDATE_SCRIPT"

# --- Firewall & TPROXY Rules ---
info "Configuring iptables REDIRECT/TPROXY rules..."

# NAT Table (TCP)
iptables -t nat -N XRAY_RV 2>/dev/null || iptables -t nat -F XRAY_RV
iptables -t nat -A XRAY_RV -d 127.0.0.0/8 -j RETURN
iptables -t nat -A XRAY_RV -p tcp -m set --match-set reverse_targets dst -j REDIRECT --to-port "${LOCAL_PORT}"
iptables -t nat -C PREROUTING -p tcp -j XRAY_RV 2>/dev/null || iptables -t nat -A PREROUTING -p tcp -j XRAY_RV
iptables -t nat -C OUTPUT -p tcp -j XRAY_RV 2>/dev/null || iptables -t nat -A OUTPUT -p tcp -j XRAY_RV

# Mangle Table (UDP TPROXY)
iptables -t mangle -N XRAY_RV 2>/dev/null || iptables -t mangle -F XRAY_RV
iptables -t mangle -A XRAY_RV -p udp -m set --match-set reverse_targets dst -j TPROXY --on-port "${LOCAL_PORT}" --tproxy-mark 2
iptables -t mangle -C PREROUTING -j XRAY_RV 2>/dev/null || iptables -t mangle -A PREROUTING -j XRAY_RV

# Block direct external access to local redirect port (REDIRECTed packets are in DNAT state)
iptables -C INPUT -p tcp --dport "${LOCAL_PORT}" -m conntrack ! --ctstate DNAT -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "${LOCAL_PORT}" -m conntrack ! --ctstate DNAT -j DROP

# --- Persistent Routing Rules (UDP TPROXY) ---
cat > /etc/systemd/system/xray-rv-routing.service <<EOF
[Unit]
Description=Apply Xray reverse TPROXY routing rules
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '/usr/sbin/ip route replace local 0.0.0.0/0 dev lo table 102'
ExecStart=/bin/bash -c '/usr/sbin/ip rule show | grep -q "fwmark 0x2 lookup 102" || /usr/sbin/ip rule add fwmark 2 lookup 102 pref 31900'

[Install]
WantedBy=multi-user.target
EOF

netfilter-persistent save
systemctl daemon-reload
systemctl enable --now xray-rv-routing.service
systemctl enable xray
systemctl restart xray

info "✅ Portal deployment complete! VLESS+WS+TLS listening on ${LISTEN_PORT}/TCP."
echo -e "${CYAN}Use these values on the bridge (exit) server:${NC}"
echo "  Domain : ${HOST}"
echo "  Port   : ${LISTEN_PORT}"
echo "  UUID   : ${UUID}"
echo "  WS path: ${WS_PATH}"
info "Add target IPs/subnets to $IP_LIST then run: $UPDATE_SCRIPT"
