#!/bin/bash
# uninstall-ups.sh — CyberDeck Pi4 UPS V5 Addon Uninstaller
#
# Removes all files installed by install-ups.sh and restores
# tft.conf SHUTDOWN_CMD to /sbin/shutdown -h now.
#
# Does NOT remove I2C configuration (harmless to leave enabled).
# Does NOT touch base cyberdeck-pi4 files beyond tft.conf.
#
# Usage: sudo ./scripts/uninstall-ups.sh

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${AMBER}[WARN]${NC}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

header "CyberDeck Pi4 — UPS V5 Addon Uninstaller"

# Stop and disable service
header "Stop service"
if systemctl is-active --quiet cyberdeck-ups 2>/dev/null; then
    systemctl stop cyberdeck-ups
    ok "cyberdeck-ups stopped"
fi
if systemctl is-enabled --quiet cyberdeck-ups 2>/dev/null; then
    systemctl disable cyberdeck-ups
    ok "cyberdeck-ups disabled"
fi

# Remove service unit
header "Remove files"
rm -f /etc/systemd/system/cyberdeck-ups.service && ok "Removed cyberdeck-ups.service"
systemctl daemon-reload

rm -f /opt/cyberdeck-pi4/scripts/ups_shutdown.sh && ok "Removed ups_shutdown.sh"
rm -rf /opt/cyberdeck-pi4/ups                    && ok "Removed /opt/cyberdeck-pi4/ups/"
rm -f /etc/cyberdeck-pi4/ups.conf                && ok "Removed ups.conf"
rm -f /etc/nginx/snippets/cyberdeck-ups.conf     && ok "Removed nginx snippet"
rm -f /etc/sudoers.d/cyberdeck-ups               && ok "Removed sudoers entry"

# Remove runtime files
rm -f /run/cyberdeck-pi4/battery.json   2>/dev/null || true
rm -f /run/cyberdeck-pi4/ups-status.json 2>/dev/null || true
ok "Removed runtime JSON files"

# Restore tft.conf SHUTDOWN_CMD
header "Restore tft.conf"
TFT_CONF=/etc/cyberdeck-pi4/tft.conf
if [ -f "${TFT_CONF}.pre-ups" ]; then
    cp "${TFT_CONF}.pre-ups" "$TFT_CONF"
    ok "Restored tft.conf from backup"
elif [ -f "$TFT_CONF" ]; then
    sed -i 's|^SHUTDOWN_CMD=.*|SHUTDOWN_CMD="/sbin/shutdown -h now"|' "$TFT_CONF"
    # Remove UPS config block
    sed -i '/^# --- UPS addon/,/^UPS_POLL_SEC/d' "$TFT_CONF"
    ok "Restored SHUTDOWN_CMD in tft.conf to /sbin/shutdown -h now"
else
    warn "tft.conf not found — nothing to restore"
fi

# Remove nginx include if it was added
for candidate in /etc/nginx/sites-enabled/cyberdeck \
                 /etc/nginx/sites-enabled/cyberdeck-pi4 \
                 /etc/nginx/conf.d/cyberdeck.conf; do
    if [ -f "$candidate" ] && grep -q "cyberdeck-ups.conf" "$candidate"; then
        sed -i '/cyberdeck-ups.conf/d' "$candidate"
        ok "Removed nginx include from $candidate"
        nginx -t && systemctl reload nginx && ok "nginx reloaded"
        break
    fi
done

# Restart services to pick up restored config
header "Restart affected services"
if systemctl is-active --quiet cyberdeck-panel 2>/dev/null; then
    systemctl restart cyberdeck-panel
    ok "cyberdeck-panel restarted"
fi

header "Uninstall complete"
echo ""
echo "  The UPS addon has been removed."
echo "  I2C remains enabled — it is safe to leave on."
echo "  The TFT panel will show NO SENSOR for the battery indicator."
echo ""
