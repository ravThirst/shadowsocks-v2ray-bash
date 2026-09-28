#!/bin/bash
set -euo pipefail

# 3x-ui panel with a VLESS + REALITY + Vision inbound for users (per-user access,
# traffic limits, expiry, share links / QR). Traffic exits this server directly.
#
# On a server set up with ss-v2ray-client.sh this still keeps split tunnelling for TCP:
# its iptables OUTPUT hook redirects Xray's connections to networks in
# /etc/proxy-ips.txt into ss-redir, everything else goes out directly.
#
# If 3x-ui is already installed, the panel is reused and only the inbound is added.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

XUI="/usr/local/x-ui/x-ui"
INSTALL_RESULT="/etc/x-ui/install-result.env"
TAG="reality-in"

apt update -qq
apt install -y jq curl openssl

# --- Interactive Inputs ---
read -rp "REALITY port [443]: " PORT
PORT=${PORT:-443}
ss -Hltn "sport = :${PORT}" | grep -q . && error "Port ${PORT} is already in use: $(ss -Hltnp "sport = :${PORT}" | head -1)"

# REALITY impersonates a real TLS 1.3 site: pick a popular HTTPS site reachable from this server,
# ideally one hosted in the same country as this server
read -rp "REALITY target site (SNI) [www.microsoft.com]: " SNI
SNI=${SNI:-www.microsoft.com}
SNI=${SNI#https://}; SNI=${SNI%%/*}; SNI=${SNI%%:*}
curl -sS -o /dev/null --tlsv1.3 --max-time 8 "https://${SNI}" \
    || error "${SNI} is not reachable over TLS 1.3 from this server, pick another site"

read -rp "Allow users to reach private networks (10.x, 192.168.x, ... e.g. via ss-redir)? [y/N]: " ALLOW_PRIVATE

# --- Install 3x-ui ---
if [[ -x "$XUI" ]]; then
    warn "3x-ui is already installed, reusing the panel"
else
    info "Installing 3x-ui (random credentials, Let's Encrypt IP certificate if port 80 is free)..."
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=ip \
        bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh) </dev/null
    [[ -x "$XUI" ]] || error "3x-ui install failed"
fi

SHOW=$("$XUI" setting -show)
PANEL_PORT=$(awk '/^port:/ {print $2}' <<<"$SHOW")
PANEL_PATH=$(awk '/^webBasePath:/ {print $2}' <<<"$SHOW")
[[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
[[ "$PANEL_PATH" != */ ]] && PANEL_PATH="$PANEL_PATH/"
[[ "$PANEL_PORT" == "$PORT" ]] && error "Port ${PORT} is used by the panel"

TOKEN=$("$XUI" setting -getApiToken -tokenName reality-setup | grep -Eo 'apiToken: .+' | awk '{print $2}' || true)
[[ -z "$TOKEN" ]] && error "Could not get 3x-ui API token"

API=""
for _ in $(seq 1 30); do
    for scheme in https http; do
        url="${scheme}://127.0.0.1:${PANEL_PORT}${PANEL_PATH}panel/api"
        if curl -fsSk -o /dev/null -H "Authorization: Bearer $TOKEN" "$url/inbounds/list"; then
            API=$url; break 2
        fi
    done
    sleep 1
done
[[ -z "$API" ]] && error "3x-ui API is not reachable on 127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

api_get() {  # path
    curl -sSk -H "Authorization: Bearer $TOKEN" "$API$1"
}

api_json() {  # path, json body
    local resp
    resp=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        --data "$2" "$API$1")
    [[ $(jq -r '.success' <<<"$resp" 2>/dev/null) == "true" ]] || error "API $1 failed: $resp"
}

# --- REALITY Inbound ---
if api_get /inbounds/list | jq -e --arg t "$TAG" '.obj[]? | select(.tag == $t)' >/dev/null; then
    warn "Inbound '$TAG' already exists, not changed"
else
    KEYS=$(api_get /server/getNewX25519Cert)
    PRIV=$(jq -r '.obj.privateKey // empty' <<<"$KEYS")
    PUB=$(jq -r '.obj.publicKey // empty' <<<"$KEYS")
    [[ -z "$PRIV" || -z "$PUB" ]] && error "Could not generate REALITY keys: $KEYS"

    STREAM=$(jq -cn --arg sni "$SNI" --arg priv "$PRIV" --arg pub "$PUB" --arg sid "$(openssl rand -hex 8)" '{
        network: "tcp", security: "reality", externalProxy: [],
        realitySettings: {
            show: false, xver: 0, target: ($sni + ":443"), serverNames: [$sni],
            privateKey: $priv, minClientVer: "", maxClientVer: "", maxTimediff: 0,
            shortIds: [$sid], mldsa65Seed: "",
            settings: { publicKey: $pub, fingerprint: "chrome", serverName: "", spiderX: "/", mldsa65Verify: "" }
        },
        tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
    }')

    SETTINGS=$(jq -cn --arg id "$(cat /proc/sys/kernel/random/uuid)" --arg sub "$(openssl rand -hex 8)" '{
        clients: [ { id: $id, email: "user1", enable: true, flow: "xtls-rprx-vision", limitIp: 0,
                     totalGB: 0, expiryTime: 0, tgId: 0, subId: $sub, reset: 0 } ],
        decryption: "none", fallbacks: []
    }')

    api_json /inbounds/add "$(jq -cn --arg tag "$TAG" --argjson port "$PORT" --arg settings "$SETTINGS" --arg stream "$STREAM" '{
        enable: true, remark: "reality", listen: "", port: $port, protocol: "vless", tag: $tag,
        total: 0, expiryTime: 0, settings: $settings, streamSettings: $stream,
        sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"routeOnly\":true}"
    }')"
    info "Inbound '$TAG' added on ${PORT}/tcp with client 'user1'"
fi

# --- Private networks ---
# 3x-ui's default template blocks geoip:private (routing rule + "direct" outbound finalRules)
if [[ "$ALLOW_PRIVATE" =~ ^[Yy]$ ]]; then
    RESP=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" "$API/xray/")
    [[ $(jq -r '.success' <<<"$RESP") == "true" ]] || error "Could not read Xray template: $RESP"
    TEMPLATE=$(jq -r '.obj' <<<"$RESP" | jq '.xraySetting
        | .routing.rules |= map(select((.ip // []) != ["geoip:private"]))
        | .outbounds |= map(if .tag == "direct" then .settings |= ((. // {}) | del(.finalRules)) else . end)')
    RESP=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" --data-urlencode "xraySetting=$TEMPLATE" "$API/xray/update")
    [[ $(jq -r '.success' <<<"$RESP") == "true" ]] || error "Could not save Xray template: $RESP"
    info "Private networks allowed for users"
fi

api_json /server/restartXrayService '{}'

# --- Firewall ---
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null
    ufw allow "${PANEL_PORT}/tcp" >/dev/null
    info "ufw: opened ${PORT}/tcp and ${PANEL_PORT}/tcp"
fi

info "✅ Done!"
if [[ -f "$INSTALL_RESULT" ]]; then
    # shellcheck disable=SC1090
    source "$INSTALL_RESULT"
    echo -e "${CYAN}Panel:${NC}"
    echo "  URL     : ${XUI_ACCESS_URL:-port ${PANEL_PORT}, path ${PANEL_PATH}}"
    echo "  Username: ${XUI_USERNAME:-?}"
    echo "  Password: ${XUI_PASSWORD:-?}"
    echo "  (saved in ${INSTALL_RESULT})"
fi
echo -e "${CYAN}Users:${NC} Inbounds -> 'reality' -> add clients, share link / QR per client"
