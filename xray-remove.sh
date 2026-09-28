#!/bin/bash
set -euo pipefail

# Completely remove standalone Xray (installed by Xray-install) so it can be reinstalled clean.
# Does NOT touch 3x-ui (/usr/local/x-ui), acme.sh or certificates.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root"

# Portal (entry server) keeps its TLS certificate inside /usr/local/etc/xray, which removal would delete
[[ -d /usr/local/etc/xray/certs ]] && \
    error "/usr/local/etc/xray/certs exists - this looks like the portal server, not the bridge. Aborting."

read -rp "This removes Xray, its config and logs. Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted"; exit 0; }

# Keep a copy of the config in case you need the values again
if [[ -f /usr/local/etc/xray/config.json ]]; then
    BACKUP="/root/xray-config-backup-$(date +%Y%m%d-%H%M%S).json"
    cp /usr/local/etc/xray/config.json "$BACKUP"
    info "Config backed up to $BACKUP"
fi

info "Stopping Xray..."
systemctl disable --now xray 2>/dev/null || true
systemctl disable --now 'xray@*' 2>/dev/null || true

info "Removing Xray..."
if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge; then
    warn "Official uninstaller failed, removing files manually"
fi

# Leftovers (also covers manual installs)
rm -f /usr/local/bin/xray
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

command -v xray &>/dev/null && warn "An xray binary is still in PATH: $(command -v xray)"
info "✅ Xray removed. Reinstall with ./xray-reverse-bridge.sh"
