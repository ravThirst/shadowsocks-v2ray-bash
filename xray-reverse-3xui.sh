#!/bin/bash
set -euo pipefail

# Move an Xray reverse PORTAL (set up by xray-reverse-portal.sh or
# xray-reverse-migrate.sh) under the 3x-ui web panel, and add a separate VLESS
# inbound for users. Uses VLESS Reverse Proxy: the bridge client on tunnel-in
# carries reverse tag "bridge-out", which becomes an outbound on this server.
#
#   tunnel-in   VLESS+WS+TLS for the bridge (same port, UUID, WS path)
#   redir-tcp   REDIRECT target for WireGuard clients (unchanged port)
#   redir-udp   TPROXY target for WireGuard clients (unchanged port)
#   clients-in  NEW: VLESS+REALITY+Vision for users, managed in the panel
# All of them exit through the bridge.
#
# If 3x-ui is already installed, runs in repair mode: updates tunnel-in,
# adds missing inbounds, converts an old WS+TLS users inbound to REALITY
# (users are kept) and rewrites the routing rules.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CERT_DIR="/usr/local/etc/xray/certs"
XUI="/usr/local/x-ui/x-ui"
REVERSE_TAG="bridge-out"

[[ -f "$XRAY_CONFIG" ]] || error "$XRAY_CONFIG not found, set up the portal first"
[[ -f "$CERT_DIR/cert.pem" && -f "$CERT_DIR/key.pem" ]] || error "Certificate not found in $CERT_DIR"

REPAIR=0
[[ -x "$XUI" ]] && REPAIR=1

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

CLIENT_PORT=8443
PANEL_USER=""
PANEL_PASS=""

if [[ $REPAIR -eq 1 ]]; then
    warn "3x-ui is already installed, running in repair mode"
    SHOW=$("$XUI" setting -show)
    PANEL_PORT=$(awk '/^port:/ {print $2}' <<<"$SHOW")
    PANEL_PATH=$(awk '/^webBasePath:/ {print $2}' <<<"$SHOW")
    [[ -z "$PANEL_PORT" || -z "$PANEL_PATH" ]] && error "Could not read panel port/path from 'x-ui setting -show'"
else
    # --- Interactive Inputs ---
    DEF_PANEL_PORT=$(shuf -i 20000-60000 -n 1)
    DEF_PANEL_PATH="/$(openssl rand -hex 8)/"
    DEF_USER="admin-$(openssl rand -hex 3)"

    read -rp "Panel port [${DEF_PANEL_PORT}]: " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-$DEF_PANEL_PORT}
    read -rp "Panel URL path [${DEF_PANEL_PATH}]: " PANEL_PATH
    PANEL_PATH=${PANEL_PATH:-$DEF_PANEL_PATH}
    read -rp "Panel username [${DEF_USER}]: " PANEL_USER
    PANEL_USER=${PANEL_USER:-$DEF_USER}
    read -rp "Panel password [random]: " PANEL_PASS
    PANEL_PASS=${PANEL_PASS:-$(openssl rand -hex 12)}
    read -rp "Users VLESS port [${CLIENT_PORT}]: " INPUT
    CLIENT_PORT=${INPUT:-$CLIENT_PORT}
fi

# REALITY impersonates a real TLS 1.3 site: pick a popular HTTPS site reachable from this server,
# ideally one hosted in the same country as this server
read -rp "REALITY target site (SNI) [www.microsoft.com]: " REALITY_SNI
REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
REALITY_SNI=${REALITY_SNI#https://}; REALITY_SNI=${REALITY_SNI%%/*}; REALITY_SNI=${REALITY_SNI%%:*}
curl -sS -o /dev/null --tlsv1.3 --max-time 8 "https://${REALITY_SNI}"     || error "${REALITY_SNI} is not reachable over TLS 1.3 from this server, pick another site"

[[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
[[ "$PANEL_PATH" != */ ]] && PANEL_PATH="$PANEL_PATH/"
for p in "$PANEL_PORT" "$CLIENT_PORT"; do
    [[ "$p" == "$TUNNEL_PORT" || "$p" == "$LOCAL_PORT" ]] && error "Port $p is already used by the portal"
done
[[ "$PANEL_PORT" == "$CLIENT_PORT" ]] && error "Panel and users port must differ"

# --- Install 3x-ui ---
if [[ $REPAIR -eq 0 ]]; then
    info "Installing 3x-ui..."
    XUI_NONINTERACTIVE=1 \
    XUI_SSL_MODE=none \
    XUI_USERNAME="$PANEL_USER" \
    XUI_PASSWORD="$PANEL_PASS" \
    XUI_PANEL_PORT="$PANEL_PORT" \
    XUI_WEB_BASE_PATH="$PANEL_PATH" \
        bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh) </dev/null
    [[ -x "$XUI" ]] || error "3x-ui install failed"
fi

TOKEN=$("$XUI" setting -getApiToken -tokenName reverse-setup | grep -Eo 'apiToken: .+' | awk '{print $2}' || true)
[[ -z "$TOKEN" ]] && error "Could not get 3x-ui API token"

# Panel serves HTTPS once a cert is set (repair mode), plain HTTP right after install
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

inbound_field() {  # tag, field
    api_get /inbounds/list | jq -r --arg t "$1" --arg f "$2" '.obj[]? | select(.tag == $t) | .[$f]'
}

# --- Hand Over Ports: stop standalone Xray ---
if systemctl is-enabled --quiet xray 2>/dev/null || systemctl is-active --quiet xray; then
    info "Stopping standalone Xray (config kept for rollback)..."
    systemctl disable --now xray
fi

# --- Inbounds ---
TLS_STREAM() {  # ws path
    jq -cn --arg path "$1" --arg cert "$CERT_DIR/cert.pem" --arg key "$CERT_DIR/key.pem" '{
        network: "ws", security: "tls",
        tlsSettings: { alpn: ["http/1.1"], certificates: [ { certificateFile: $cert, keyFile: $key } ] },
        wsSettings: { path: $path }
    }'
}

client_json() {  # uuid email [reverse tag]
    jq -cn --arg id "$1" --arg email "$2" --arg rv "${3:-}" --arg sub "$(openssl rand -hex 8)" '
        { id: $id, email: $email, enable: true, flow: "", limitIp: 0, totalGB: 0, expiryTime: 0, tgId: 0, subId: $sub, reset: 0 }
        + (if $rv != "" then { reverse: { tag: $rv } } else {} end)'
}

inbound_body() {  # tag remark port protocol settings stream
    jq -cn --arg tag "$1" --arg remark "$2" --argjson port "$3" --arg proto "$4" \
        --arg settings "$5" --arg stream "$6" '{
        enable: true, remark: $remark, listen: "", port: $port, protocol: $proto, tag: $tag,
        total: 0, expiryTime: 0, settings: $settings, streamSettings: $stream,
        sniffing: "{\"enabled\":false}"
    }'
}

# Existing inbounds are updated in place: deleting one in 3x-ui only detaches its
# clients, so re-adding the same client email would fail.
ensure_inbound() {  # overwrite(0/1) tag remark port protocol settings stream
    local overwrite=$1 tag=$2 id
    id=$(inbound_field "$tag" id)
    if [[ -z "$id" ]]; then
        api_json /inbounds/add "$(inbound_body "${@:2}")"
        info "Inbound '$tag' added"
    elif [[ $overwrite -eq 1 ]]; then
        api_json "/inbounds/update/$id" "$(inbound_body "${@:2}")"
        info "Inbound '$tag' updated"
    else
        info "Inbound '$tag' exists, kept"
    fi
}

REALITY_STREAM() {  # sni private-key public-key short-id
    jq -cn --arg sni "$1" --arg priv "$2" --arg pub "$3" --arg sid "$4" '{
        network: "tcp", security: "reality", externalProxy: [],
        realitySettings: {
            show: false, xver: 0, target: ($sni + ":443"), serverNames: [$sni],
            privateKey: $priv, minClientVer: "", maxClientVer: "", maxTimediff: 0,
            shortIds: [$sid], mldsa65Seed: "",
            settings: { publicKey: $pub, fingerprint: "chrome", serverName: "", spiderX: "/", mldsa65Verify: "" }
        },
        tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
    }'
}

ensure_inbound 1 tunnel-in "reverse-bridge (do not edit)" "$TUNNEL_PORT" vless \
    "$(jq -cn --argjson c "$(client_json "$BRIDGE_UUID" bridge "$REVERSE_TAG")" '{ clients: [$c], decryption: "none", fallbacks: [] }')" \
    "$(TLS_STREAM "$TUNNEL_PATH")"

ensure_inbound 0 redir-tcp "redirect-tcp (do not edit)" "$LOCAL_PORT" tunnel \
    '{"allowedNetwork":"tcp","followRedirect":true}' \
    '{"network":"tcp","security":"none","sockopt":{"tproxy":"redirect"}}'

ensure_inbound 0 redir-udp "redirect-udp (do not edit)" "$LOCAL_PORT" tunnel \
    '{"allowedNetwork":"udp","followRedirect":true}' \
    '{"network":"tcp","security":"none","sockopt":{"tproxy":"tproxy"}}'

# Users inbound: VLESS + REALITY + Vision. An existing one is converted in place, keeping its users and port.
KEYS=$(api_get /server/getNewX25519Cert)
REALITY_PRIV=$(jq -r '.obj.privateKey // empty' <<<"$KEYS")
REALITY_PUB=$(jq -r '.obj.publicKey // empty' <<<"$KEYS")
[[ -z "$REALITY_PRIV" || -z "$REALITY_PUB" ]] && error "Could not generate REALITY keys: $KEYS"
STREAM=$(REALITY_STREAM "$REALITY_SNI" "$REALITY_PRIV" "$REALITY_PUB" "$(openssl rand -hex 8)")

CLIENTS_ID=$(inbound_field clients-in id)
if [[ -n "$CLIENTS_ID" ]]; then
    CLIENT_PORT=$(inbound_field clients-in port)
    SETTINGS=$(inbound_field clients-in settings | jq -c '.clients |= map(.flow = "xtls-rprx-vision") | .decryption = "none"')
    api_json "/inbounds/update/$CLIENTS_ID" "$(inbound_body clients-in "users" "$CLIENT_PORT" vless "$SETTINGS" "$STREAM")"
    info "Inbound 'clients-in' switched to REALITY (users kept)"
else
    SETTINGS=$(jq -cn --argjson c "$(client_json "$(cat /proc/sys/kernel/random/uuid)" user1)"         '{ clients: [$c | .flow = "xtls-rprx-vision"], decryption: "none", fallbacks: [] }')
    api_json /inbounds/add "$(inbound_body clients-in "users" "$CLIENT_PORT" vless "$SETTINGS" "$STREAM")"
    info "Inbound 'clients-in' added (REALITY)"
fi

# --- Xray Template: routing to the bridge ---
info "Configuring routing to the bridge in 3x-ui Xray template..."
RESP=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" "$API/xray/")
[[ $(jq -r '.success' <<<"$RESP") == "true" ]] || error "Could not read Xray template: $RESP"

# Rules go right after the panel's own "api" rule, before its geoip:private block rule
# (redirected subnets are often private ranges). Old rules for our inbounds are replaced.
TEMPLATE=$(jq -r '.obj' <<<"$RESP" | jq --arg rv "$REVERSE_TAG" '.xraySetting
    | del(.reverse)
    | .routing.rules as $r
    | ["tunnel-in", "redir-tcp", "redir-udp", "clients-in"] as $ours
    | .routing.rules =
        ($r | map(select(.inboundTag == ["api"])))
        + [
            { type: "field", inboundTag: ["redir-tcp", "redir-udp", "clients-in"], outboundTag: $rv },
            { type: "field", inboundTag: ["tunnel-in"], outboundTag: "blocked" }
          ]
        + ($r | map(select(.inboundTag != ["api"] and (((.inboundTag // []) - $ours) == (.inboundTag // [])))))')

RESP=$(curl -sSk -X POST -H "Authorization: Bearer $TOKEN" --data-urlencode "xraySetting=$TEMPLATE" "$API/xray/update")
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

info "✅ 3x-ui panel configured as reverse portal!"
echo -e "${CYAN}Panel:${NC}"
echo "  URL     : https://${HOST}:${PANEL_PORT}${PANEL_PATH}"
if [[ $REPAIR -eq 0 ]]; then
    echo "  Username: ${PANEL_USER}"
    echo "  Password: ${PANEL_PASS}"
fi
echo -e "${CYAN}Users inbound:${NC} 'users' on ${CLIENT_PORT}/tcp (VLESS+REALITY+Vision, SNI ${REALITY_SNI})"
echo -e "${YELLOW}Clients must re-import their links / QR codes from the panel.${NC}"
echo -e "${YELLOW}Bridge must use VLESS Reverse Proxy: re-run xray-reverse-bridge.sh on the exit server.${NC}"
echo -e "${YELLOW}Do not edit or delete inbounds marked '(do not edit)' or the 'bridge' client.${NC}"
echo -e "${CYAN}Rollback:${NC} systemctl disable --now x-ui && systemctl enable --now xray"
