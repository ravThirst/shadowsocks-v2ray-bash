#!/bin/bash
set -euo pipefail

# --- Color Output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# --- Root Check ---
[[ $EUID -ne 0 ]] && error "This script must be run as root"

# --- Interactive Inputs ---
read -rp "Enter domain name (e.g., asd.domain.com): " HOST
read -rp "Enter Shadowsocks password: " SS_PASSWORD
read -rp "Enter ACME email: " ACME_EMAIL

[[ -z "$HOST" || -z "$SS_PASSWORD" || -z "$ACME_EMAIL" ]] && error "Domain, Password, and Email are required"

# --- DNS Validation Method Selection ---
echo -e "\n${CYAN}Select Certificate Validation Method:${NC}"
echo "  1) Cloudflare DNS-01 (Recommended for CDN/proxied domains)"
echo "  2) HTTP-01 / ALPN (Direct server validation, port 80 must be free initially)"
read -rp "Enter choice [1/2]: " DNS_CHOICE

CF_TOKEN=""
ACME_DNS_FLAG=""
if [[ "$DNS_CHOICE" == "1" ]]; then
    read -rp "Enter Cloudflare API Token: " CF_TOKEN
    [[ -z "$CF_TOKEN" ]] && error "Cloudflare API Token is required for DNS-01"
    export CF_Token="$CF_TOKEN"
    ACME_DNS_FLAG="--dns dns_cf"
    info "Using Cloudflare DNS-01 validation"
elif [[ "$DNS_CHOICE" == "2" ]]; then
    ACME_DNS_FLAG=""
    info "Using HTTP-01/ALPN validation (ensure port 80 is not occupied by another web server)"
else
    error "Invalid choice. Please enter 1 or 2."
fi

# --- System Dependencies ---
info "Installing system dependencies..."
apt update -qq
apt install -y shadowsocks-libev cron curl tar socat

# --- Go Installation ---
GO_VERSION="1.26.2"
if ! command -v go &>/dev/null || [[ $(go version 2>/dev/null | grep -oP '\d+\.\d+\.\d+') != "$GO_VERSION" ]]; then
    info "Installing Go $GO_VERSION..."
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz

    PROFILE="/root/.profile"
    if ! grep -q "/usr/local/go/bin" "$PROFILE"; then
        cat >> "$PROFILE" <<EOF
export PATH=\$PATH:/usr/local/go/bin
export GOPATH=\$HOME/goproject
export PATH=\$PATH:\$GOPATH/bin
EOF
    fi
    export PATH=$PATH:/usr/local/go/bin:$HOME/goproject/bin
fi
info "Go version: $(go version)"

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

# --- ACME.sh & Certificate ---
if [[ ! -d /root/.acme.sh ]]; then
    info "Installing acme.sh..."
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
fi

CERT_DIR="/etc/shadowsocks-libev/certs"
mkdir -p "$CERT_DIR"

info "Issuing certificate for $HOST..."
# shellcheck disable=SC2086
/root/.acme.sh/acme.sh --issue $ACME_DNS_FLAG --alpn --force \
    -d "$HOST" \
    --server https://acme-v02.api.letsencrypt.org/directory

/root/.acme.sh/acme.sh --install-cert -d "$HOST" --ecc \
    --fullchain-file "$CERT_DIR/cert.pem" \
    --key-file "$CERT_DIR/key.pem" \
    --reloadcmd "systemctl restart shadowsocks-libev"

chmod 644 "$CERT_DIR"/*

# --- Shadowsocks Config ---
info "Writing Shadowsocks configuration..."
cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": 443,
    "password": "${SS_PASSWORD}",
    "method": "chacha20-ietf-poly1305",
    "timeout": 81300,
    "plugin": "/usr/local/bin/v2ray-plugin",
    "plugin_opts": "server;tls;host=${HOST};cert=${CERT_DIR}/cert.pem;key=${CERT_DIR}/key.pem",
    "mode": "tcp_and_udp"
}
EOF

grep -q "^HOME=/root" /etc/default/shadowsocks-libev 2>/dev/null || echo "HOME=/root" >> /etc/default/shadowsocks-libev

# --- Renewal Cron ---
RENEW_SCRIPT="/usr/local/bin/renew-shadowsocks-cert.sh"
cat > "$RENEW_SCRIPT" <<RENEWEOF
#!/bin/bash
set -euo pipefail
HOST="${HOST}"
ACME_DNS_FLAG="${ACME_DNS_FLAG}"
LOGFILE="/var/log/acme-shadowsocks-renew.log"
exec >> "\$LOGFILE" 2>&1
echo "=== \$(date) ==="
~/.acme.sh/acme.sh --issue \$ACME_DNS_FLAG --alpn --force \\
    -d "\$HOST" \\
    --server https://acme-v02.api.letsencrypt.org/directory
if [ \$? -eq 0 ]; then
    echo "✓ Certificate renewed"
    systemctl restart shadowsocks-libev
    echo "✓ Service restarted"
else
    echo "✗ Renewal failed" >&2
    exit 1
fi
RENEWEOF
chmod +x "$RENEW_SCRIPT"

(crontab -l 2>/dev/null | grep -v "renew-shadowsocks-cert.sh"; echo "0 0 1 */2 * $RENEW_SCRIPT") | crontab -

# --- Start Services ---
systemctl enable --now shadowsocks-libev cron
info "✅ Server deployment complete! Port 443/TCP is active."