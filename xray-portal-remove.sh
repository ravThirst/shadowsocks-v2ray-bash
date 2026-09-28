#!/bin/bash
set -uo pipefail

# Remove the Xray reverse PORTAL from the entry server: 3x-ui panel, standalone Xray,
# and the redirect rules created by xray-reverse-portal.sh. For a server migrated from
# ss-v2ray-client.sh, offers to switch back to ss-redir (old tunnel).
# Everything that gets deleted is backed up to /root/xray-portal-backup-<date>/ first.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CERT="/usr/local/etc/xray/certs/cert.pem"
XUI="/usr/local/x-ui/x-ui"
SS_CONFIG="/etc/shadowsocks-libev/ss-redir.json"

# --- Collect info before anything is deleted ---
HOST=""
[[ -f "$CERT" ]] && HOST=$(openssl x509 -in "$CERT" -noout -subject -nameopt RFC2253 | sed 's/.*CN=//; s/,.*//')
PANEL_PORT=""
[[ -x "$XUI" ]] && PANEL_PORT=$("$XUI" setting -show 2>/dev/null | awk '/^port:/ {print $2}')

echo "This will remove:"
[[ -x "$XUI" ]] && echo "  - 3x-ui panel (/usr/local/x-ui, /etc/x-ui) including its users database"
[[ -x /usr/local/bin/xray || -f "$XRAY_CONFIG" ]] && echo "  - standalone Xray (/usr/local/etc/xray)"
iptables -t nat -S XRAY_RV &>/dev/null && echo "  - redirect rules for /etc/reverse-ips.txt (ipset reverse_targets)"
read -rp "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted"; exit 0; }

REMOVE_CERT=n
if [[ -n "$HOST" ]]; then
    read -rp "Also remove the certificate for ${HOST} and its auto-renewal? [y/N]: " REMOVE_CERT
fi
RESTORE_SS=n
if [[ -f "$SS_CONFIG" ]]; then
    read -rp "Re-enable ss-redir (old shadowsocks tunnel) for /etc/proxy-ips.txt? [Y/n]: " RESTORE_SS
    RESTORE_SS=${RESTORE_SS:-y}
fi

# --- Backup ---
BACKUP="/root/xray-portal-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
[[ -d /usr/local/etc/xray ]] && cp -a /usr/local/etc/xray "$BACKUP/xray-etc"
[[ -d /etc/x-ui ]] && cp -a /etc/x-ui "$BACKUP/x-ui-etc"
[[ -f /etc/reverse-ips.txt ]] && cp -a /etc/reverse-ips.txt "$BACKUP/"
info "Backup saved to $BACKUP"

# --- 3x-ui ---
if [[ -x "$XUI" ]] || systemctl list-unit-files x-ui.service &>/dev/null; then
    info "Removing 3x-ui..."
    systemctl disable --now x-ui 2>/dev/null
    rm -rf /usr/local/x-ui /etc/x-ui
    rm -f /etc/systemd/system/x-ui.service /usr/bin/x-ui
    # fail2ban IP-limit jail installed by 3x-ui
    if ls /etc/fail2ban/jail.d/3x-ipl.conf &>/dev/null; then
        rm -f /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
        systemctl restart fail2ban 2>/dev/null
    fi
    if [[ -n "$PANEL_PORT" ]] && command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "${PANEL_PORT}/tcp" >/dev/null 2>&1
        info "ufw: closed panel port ${PANEL_PORT}/tcp"
    fi
fi

# --- Standalone Xray ---
if [[ -x /usr/local/bin/xray || -d /usr/local/etc/xray ]]; then
    info "Removing standalone Xray..."
    systemctl disable --now xray 2>/dev/null
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge \
        || warn "Official uninstaller failed, removing files manually"
    rm -f /usr/local/bin/xray /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray \
        /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
fi
systemctl daemon-reload
systemctl reset-failed 2>/dev/null

# --- Redirect rules from xray-reverse-portal.sh ---
if iptables -t nat -S XRAY_RV &>/dev/null; then
    info "Removing reverse redirect rules..."
    while iptables -t nat -D PREROUTING -p tcp -j XRAY_RV 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p tcp -j XRAY_RV 2>/dev/null; do :; done
    while iptables -t mangle -D PREROUTING -j XRAY_RV 2>/dev/null; do :; done
    iptables -t nat -F XRAY_RV; iptables -t nat -X XRAY_RV
    iptables -t mangle -F XRAY_RV 2>/dev/null; iptables -t mangle -X XRAY_RV 2>/dev/null
    # INPUT drop rule protecting the redirect port (only the portal script adds the conntrack variant)
    iptables -S INPUT | grep -- '! --ctstate DNAT -j DROP' | sed 's/^-A /-D /' | while read -r rule; do
        eval "iptables $rule" 2>/dev/null
    done
    ipset destroy reverse_targets 2>/dev/null
    systemctl disable --now xray-rv-routing.service 2>/dev/null
    rm -f /etc/systemd/system/xray-rv-routing.service /usr/local/bin/update-reverse-ips.sh /etc/reverse-ips.txt
    ip rule del fwmark 2 lookup 102 2>/dev/null
    ip route flush table 102 2>/dev/null
    systemctl daemon-reload
    netfilter-persistent save >/dev/null 2>&1
fi

# --- Back to ss-redir (migrated setup) ---
if [[ "$RESTORE_SS" =~ ^[Yy]$ ]]; then
    systemctl enable --now ss-redir && info "ss-redir re-enabled, /etc/proxy-ips.txt goes through the old tunnel again"
elif [[ -f "$SS_CONFIG" ]]; then
    warn "ss-redir stays disabled: networks in /etc/proxy-ips.txt are still redirected but have no proxy now"
fi

# --- Certificate ---
if [[ -n "$HOST" && -d /root/.acme.sh ]]; then
    ACME_CONF="/root/.acme.sh/${HOST}_ecc/${HOST}.conf"
    if [[ "$REMOVE_CERT" =~ ^[Yy]$ ]]; then
        /root/.acme.sh/acme.sh --remove -d "$HOST" --ecc >/dev/null 2>&1
        rm -rf "/root/.acme.sh/${HOST}_ecc"
        info "Certificate for ${HOST} removed"
    elif [[ -f "$ACME_CONF" ]]; then
        # Keep the cert, but renewal must not try to stop/restart services that no longer exist
        sed -i '/^Le_PreHook=/d; /^Le_PostHook=/d; /^Le_ReloadCmd=/d; /^Le_RealCertPath=/d; /^Le_RealKeyPath=/d; /^Le_RealFullChainPath=/d' "$ACME_CONF"
        info "Certificate for ${HOST} kept in /root/.acme.sh (renewal hooks cleared)"
    fi
fi

info "✅ Portal removed."
warn "If ufw is active, close the users inbound port yourself (default 8443): ufw delete allow 8443/tcp"
