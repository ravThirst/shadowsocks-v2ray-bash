#!/bin/bash
set -euo pipefail

# Move an Xray reverse PORTAL (set up by xray-reverse-portal.sh or
# xray-reverse-migrate.sh) under the 3x-ui web panel, and add a separate VLESS
# inbound for users. Bridge side needs no changes: same port, UUID and WS path.
#
#   tunnel-in   VLESS+WS+TLS for the bridge (unchanged)
#   redir-tcp   REDIRECT target for WireGuard clients (unchanged port)
#   redir-udp   TPROXY target for WireGuard clients (unchanged port)
#   clients-in  NEW: VLESS+WS+TLS for users, managed in the panel
# All of them exit through the bridge.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CERT_DIR="/usr/local/etc/xray/certs"
XUI="/usr/local/x-ui/x-ui"

[[ -f "$XRAY_CONFIG" ]] || error "$XRAY_CONFIG not found, set up the portal first"
[[ -f "$CERT_DIR/cert.pem" && -f "$CERT_DIR/key.pem" ]] || error "Certificate not found in $CERT_DIR"
[[ -x "$XUI" ]] && error "3x-ui is already installed, this script is for a fresh panel install"

apt update -qq
apt install -y jq curl openssl

# --- Read Existing Portal Config ---
IN_TUNNEL='.inbounds[] | select(.tag == "tunnel-in")'
jq -e "$IN_TUNNEL" "$XRAY_CONFIG" >/dev/null || error "No 'tunnel-in' inbound in $XRAY_CONFIG"

BRIDGE_UUID=$(jq -r "$IN_TUNNEL | .settings.clients[0].id" "$XRAY_CONFIG")
TUNNEL_PORT=$(jq -r "$IN_TUNNEL | .port" "$XRAY_CONFIG")
TUNNEL_PATH=$(jq -r "$IN_TUNNEL | .streamSettings.wsSettings.path" "$XRAY_CONFIG")
LOCAL_PORT=$(jq -r '.inbounds[] | select(.tag == "redir-tcp") | .port' "$XRAY_CONFIG")
HOST=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -subject -nameopt RFC2253 | sed 's/.*CN=//; s/,.*//')
[[ -z "$LOCAL_PORT" ]] && error "No 'redir-tcp' inbound in $XRAY_CONFIG"

info "Found portal: ${HOST}:${TUNNEL_PORT}, WS path ${TUNNEL_PATH}, redirect port ${LOCAL_PORT}"

# --- Interactive Inputs ---
DEF_PANEL_PORT=$(shuf -i 20000-60000 -n 1)
DEF_PANEL_PATH="/$(openssl rand -hex 8)/"
DEF_USER="admin-$(openssl rand -hex 3)"
DEF_PASS=$(openssl rand -hex 12)
DEF_CLIENT_PATH="/$(openssl rand -hex 12)"

read -rp "Panel port [${DEF_PANEL_PORT}]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-$DEF_PANEL_PORT}
read -rp "Panel URL path [${DEF_PANEL_PATH}]: " PANEL_PATH
PANEL_PATH=${PANEL_PATH:-$DEF_PANEL_PATH}
read -rp "Panel username [${DEF_USER}]: " PANEL_USER
PANEL_USER=${PANEL_USER:-$DEF_USER}
read -rp "Panel password [random]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-$DEF_PASS}
read -rp "Users VLESS port [8443]: " CLIENT_PORT
CLIENT_PORT=${CLIENT_PORT:-8443}
read -rp "Users WebSocket path [random]: " CLIENT_PATH
CLIENT_PATH=${CLIENT_PATH:-$DEF_CLIENT_PATH}

[[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
[[ "$PANEL_PATH" != */ ]] && PANEL_PATH="$PANEL_PATH/"
[[ "$CLIENT_PATH" != /* ]] && CLIENT_PATH="/$CLIENT_PATH"
for p in "$PANEL_PORT" "$CLIENT_PORT"; do
    [[ "$p" == "$TUNNEL_PORT" || "$p" == "$LOCAL_PORT" ]] && error "Port $p is already used by the portal"
done
[[ "$PANEL_PORT" == "$CLIENT_PORT" ]] && error "Panel and users port must differ"

# --- Install 3x-ui ---
info "Installing 3x-ui..."
XUI_NONINTERACTIVE=1 \
XUI_SSL_MODE=none \
XUI_USERNAME="$PANEL_USER" \
XUI_PASSWORD="$PANEL_PASS" \
XUI_PANEL_PORT="$PANEL_PORT" \
XUI_WEB_BASE_PATH="$PANEL_PATH" \
    bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh) </dev/null

[[ -x "$XUI" ]] || error "3x-ui install failed"

TOKEN=$("$XUI" setting -getApiToken -tokenName reverse-setup | grep -Eo 'apiToken: .+' | awk '{print $2}' || true)
[[ -z "$TOKEN" ]] && error "Could not get 3x-ui API token"

API="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}panel/api"

# Wait for panel API
for _ in $(seq 1 30); do
    curl -fsS -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/inbounds/list" && break
    sleep 1
done

api_json() {  # path, json body
    local resp
    resp=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        --data "$2" "$API$1")
    [[ $(jq -r '.success' <<<"$resp" 2>/dev/null) == "true" ]] || error "API $1 failed: $resp"
}

# --- Hand Over Ports: stop standalone Xray ---
info "Stopping standalone Xray (config kept for rollback)..."
systemctl disable --now xray

# --- Inbounds ---
TLS_STREAM() {  # ws path
    jq -cn --arg path "$1" --arg cert "$CERT_DIR/cert.pem" --arg key "$CERT_DIR/key.pem" '{
        network: "ws", security: "tls",
        tlsSettings: { alpn: ["http/1.1"], certificates: [ { certificateFile: $cert, keyFile: $key } ] },
        wsSettings: { path: $path }
    }'
}

add_inbound() {  # tag remark port protocol settings stream
    api_json /inbounds/add "$(jq -cn --arg tag "$1" --arg remark "$2" --argjson port "$3" --arg proto "$4" \
        --arg settings "$5" --arg stream "$6" '{
        enable: true, remark: $remark, listen: "", port: $port, protocol: $proto, tag: $tag,
        total: 0, expiryTime: 0, settings: $settings, streamSettings: $stream,
        sniffing: "{\"enabled\":false}"
    }')"
    info "Inbound '$1' added"
}

client_json() {  # uuid email
    jq -cn --arg id "$1" --arg email "$2" --arg sub "$(openssl rand -hex 8)" \
        '{ id: $id, email: $email, enable: true, flow: "", limitIp: 0, totalGB: 0, expiryTime: 0, tgId: 0, subId: $sub, reset: 0 }'
}

add_inbound tunnel-in "reverse-bridge (do not edit)" "$TUNNEL_PORT" vless \
    "$(jq -cn --argjson c "$(client_json "$BRIDGE_UUID" bridge)" '{ clients: [$c], decryption: "none", fallbacks: [] }')" \
    "$(TLS_STREAM "$TUNNEL_PATH")"

add_inbound redir-tcp "redirect-tcp (do not edit)" "$LOCAL_PORT" tunnel \
    '{"allowedNetwork":"tcp","followRedirect":true}' \
    '{"network":"tcp","security":"none","sockopt":{"tproxy":"redirect"}}'

add_inbound redir-udp "redirect-udp (do not edit)" "$LOCAL_PORT" tunnel \
    '{"allowedNetwork":"udp","followRedirect":true}' \
    '{"network":"tcp","security":"none","sockopt":{"tproxy":"tproxy"}}'

FIRST_UUID=$(cat /proc/sys/kernel/random/uuid)
add_inbound clients-in "users" "$CLIENT_PORT" vless \
    "$(jq -cn --argjson c "$(client_json "$FIRST_UUID" user1)" '{ clients: [$c], decryption: "none", fallbacks: [] }')" \
    "$(TLS_STREAM "$CLIENT_PATH")"

# --- Xray Template: reverse portal + routing ---
info "Configuring reverse portal routing in 3x-ui Xray template..."
RESP=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" "$API/xray/")
[[ $(jq -r '.success' <<<"$RESP") == "true" ]] || error "Could not read Xray template: $RESP"

# Rules go right after the panel's own "api" rule, before its geoip:private block rule
# (redirected subnets are often private ranges)
TEMPLATE=$(jq -r '.obj' <<<"$RESP" | jq '.xraySetting
    | .reverse = { portals: [ { tag: "portal", domain: "reverse.internal" } ] }
    | .routing.rules as $r
    | ["tunnel-in", "redir-tcp", "redir-udp", "clients-in"] as $ours
    | .routing.rules =
        ($r | map(select(.inboundTag == ["api"])))
        + [
            { type: "field", inboundTag: ["tunnel-in"], domain: ["full:reverse.internal"], outboundTag: "portal" },
            { type: "field", inboundTag: ["redir-tcp", "redir-udp", "clients-in"], outboundTag: "portal" },
            { type: "field", inboundTag: ["tunnel-in"], outboundTag: "blocked" }
          ]
        + ($r | map(select(.inboundTag != ["api"] and (((.inboundTag // []) - $ours) == (.inboundTag // [])))))')

RESP=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" --data-urlencode "xraySetting=$TEMPLATE" "$API/xray/update")
[[ $(jq -r '.success' <<<"$RESP") == "true" ]] || error "Could not save Xray template: $RESP"

api_json /server/restartXrayService '{}'

# --- Panel HTTPS with the portal certificate ---
info "Enabling HTTPS for the panel..."
"$XUI" cert -webCert "$CERT_DIR/cert.pem" -webCertKey "$CERT_DIR/key.pem" >/dev/null
systemctl restart x-ui

# --- Cert renewal now restarts x-ui instead of xray ---
ACME_CONF="/root/.acme.sh/${HOST}_ecc/${HOST}.conf"
if [[ -f "$ACME_CONF" ]]; then
    b64() { echo "__ACME_BASE64__START_$(printf '%s' "$1" | base64 -w0)__ACME_BASE64__END_"; }
    grep -q "^Le_PreHook=" "$ACME_CONF" && \
        sed -i "s|^Le_PreHook=.*|Le_PreHook='$(b64 'systemctl stop x-ui || true')'|" "$ACME_CONF"
    grep -q "^Le_PostHook=" "$ACME_CONF" && \
        sed -i "s|^Le_PostHook=.*|Le_PostHook='$(b64 'systemctl start x-ui || true')'|" "$ACME_CONF"
    /root/.acme.sh/acme.sh --install-cert -d "$HOST" --ecc \
        --fullchain-file "$CERT_DIR/cert.pem" \
        --key-file "$CERT_DIR/key.pem" \
        --reloadcmd "systemctl restart x-ui" >/dev/null
    info "acme.sh renewal hooks switched to x-ui"
else
    warn "$ACME_CONF not found, update your cert renewal to restart x-ui manually"
fi

# --- Firewall ---
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${PANEL_PORT}/tcp" >/dev/null
    ufw allow "${CLIENT_PORT}/tcp" >/dev/null
    info "ufw: opened ${PANEL_PORT}/tcp and ${CLIENT_PORT}/tcp"
fi

info "✅ 3x-ui panel installed and portal migrated!"
echo -e "${CYAN}Panel:${NC}"
echo "  URL     : https://${HOST}:${PANEL_PORT}${PANEL_PATH}"
echo "  Username: ${PANEL_USER}"
echo "  Password: ${PANEL_PASS}"
echo -e "${CYAN}Users inbound:${NC} 'users' on ${CLIENT_PORT}/tcp (VLESS+WS+TLS, path ${CLIENT_PATH}), first client 'user1'"
echo -e "${YELLOW}Do not edit or delete inbounds marked '(do not edit)' or the 'bridge' client.${NC}"
echo -e "${CYAN}Rollback:${NC} systemctl disable --now x-ui && systemctl enable --now xray"
