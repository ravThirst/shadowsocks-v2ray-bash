#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

# --- Interactive Inputs ---
read -rp "Enter server IP address: " SERVER_IP
read -rp "Enter server hostname (TLS SNI): " SERVER_HOST
read -rp "Enter Shadowsocks password: " SS_PASSWORD
read -rp "Enter local redirect port [12345]: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-12345}

[[ -z "$SERVER_IP" || -z "$SERVER_HOST" || -z "$SS_PASSWORD" ]] && error "Server IP, Host, and Password are required"

# --- Dependencies ---
info "Installing client dependencies..."
apt update -qq
apt install -y shadowsocks-libev ipset netfilter-persistent iptables

systemctl enable --now netfilter-persistent

# --- V2Ray Plugin ---
V2RAY_VER="v1.3.2"
if [[ ! -x /usr/local/bin/v2ray-plugin ]]; then
    info "Installing v2ray-plugin $V2RAY_VER..."
    wget -q "https://github.com/shadowsocks/v2ray-plugin/releases/download/${V2RAY_VER}/v2ray-plugin-linux-amd64-${V2RAY_VER}.tar.gz" -O /tmp/v2ray-plugin.tar.gz
    tar -xzf /tmp/v2ray-plugin.tar.gz -C /tmp
    mv /tmp/v2ray-plugin_* /usr/local/bin/v2ray-plugin
    chmod +x /usr/local/bin/v2ray-plugin
    rm -rf /tmp/v2ray-plugin*
fi

# --- SS-Redir Config ---
CONFIG_PATH="/etc/shadowsocks-libev/ss-redir.json"
cat > "$CONFIG_PATH" <<EOF
{
    "server": "${SERVER_IP}",
    "server_port": 443,
    "password": "${SS_PASSWORD}",
    "method": "chacha20-ietf-poly1305",
    "local_address": "0.0.0.0",
    "local_port": ${LOCAL_PORT},
    "plugin": "/usr/local/bin/v2ray-plugin",
    "plugin_opts": "tls;host=${SERVER_HOST}",
    "mode": "tcp_and_udp"
}
EOF

# --- Systemd Service ---
cat > /etc/systemd/system/ss-redir.service <<EOF
[Unit]
Description=Shadowsocks Redir Client
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/ss-redir -c ${CONFIG_PATH} -u -v
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- IPSet Management Script ---
IP_LIST="/etc/proxy-ips.txt"
UPDATE_SCRIPT="/usr/local/bin/update-proxy-ips.sh"

[[ ! -f "$IP_LIST" ]] && touch "$IP_LIST"

cat > "$UPDATE_SCRIPT" <<'IPEOF'
#!/bin/bash
IPSET_NAME="proxy_targets"
IP_LIST="/etc/proxy-ips.txt"
ipset create ${IPSET_NAME}_new hash:net -exist
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

# --- Initial IPSet Creation ---
"$UPDATE_SCRIPT"

# --- Firewall & TPROXY Rules ---
info "Configuring iptables TPROXY and NAT rules..."

# NAT Table (TCP)
iptables -t nat -N REDSOCKS 2>/dev/null || iptables -t nat -F REDSOCKS
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d "${SERVER_IP}" -j RETURN
iptables -t nat -A REDSOCKS -p tcp -m set --match-set proxy_targets dst -j REDIRECT --to-port "${LOCAL_PORT}"
iptables -t nat -A PREROUTING -p tcp -j REDSOCKS
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

# Block external access to local redir port
iptables -C INPUT -p tcp --dport "${LOCAL_PORT}" -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "${LOCAL_PORT}" -j DROP

# Mangle Table (UDP TPROXY)
iptables -t mangle -N REDSOCKS 2>/dev/null || iptables -t mangle -F REDSOCKS
iptables -t mangle -A REDSOCKS -p udp -m set --match-set proxy_targets dst -j TPROXY --on-port "${LOCAL_PORT}" --tproxy-mark 1
iptables -t mangle -A PREROUTING -j REDSOCKS

# --- Persistent Routing Rules ---
TPROXY_SERVICE="/etc/systemd/system/tproxy-routing.service"
cat > "$TPROXY_SERVICE" <<EOF
[Unit]
Description=Apply TProxy Routing Rules
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip route add local default dev lo table 100
ExecStart=/usr/sbin/ip rule add fwmark 1 lookup 100 pref 32000
ExecStart=/usr/sbin/ip route add local 0.0.0.0/0 dev lo table tproxy
ExecStart=/usr/sbin/ip rule add fwmark 0x1 lookup tproxy pref 32000

[Install]
WantedBy=multi-user.target
EOF

# Apply immediately
ip route add local default dev lo table 100 2>/dev/null || true
ip rule add fwmark 1 lookup 100 pref 32000 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table tproxy 2>/dev/null || true
ip rule add fwmark 0x1 lookup tproxy pref 32000 2>/dev/null || true

netfilter-persistent save
systemctl daemon-reload
systemctl enable --now ss-redir.service tproxy-routing.service

info "✅ Client deployment complete!"
info "Add target IPs/subnets to $IP_LIST then run: $UPDATE_SCRIPT"