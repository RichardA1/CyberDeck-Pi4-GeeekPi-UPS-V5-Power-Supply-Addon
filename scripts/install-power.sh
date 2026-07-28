#!/bin/bash
# install-power.sh — CyberDeck Pi4 Power Management Page Installer
#
# Installs:
#   - power.html to /var/www/html/
#   - power-api.py to /opt/cyberdeck-pi4/power/
#   - cyberdeck-power-api.service
#   - nginx proxy entries for /api/lowpower, /api/ups/threshold, /api/ups/backtoac
#   - Adds Power tab link to index.html, devices.html, mqtt.html
#   - Adds UPS_SHUTDOWN_THRESHOLD key to ups.conf
#
# Usage: sudo bash install-power.sh

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

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB_ROOT="/var/www/html"
OPT_DIR="/opt/cyberdeck-pi4/power"
CONF_FILE="/etc/cyberdeck-pi4/ups.conf"

header "CyberDeck Pi4 — Power Management Installer"

# ---------------------------------------------------------------------------
# Install power.html
# ---------------------------------------------------------------------------
header "Step 1 — Install power.html"
install -m 644 "$REPO_DIR/../web/power.html" "$WEB_ROOT/power.html"
chown www-data:webedit "$WEB_ROOT/power.html" 2>/dev/null || true
ok "Installed: $WEB_ROOT/power.html"

# ---------------------------------------------------------------------------
# Add Power tab to existing pages
# ---------------------------------------------------------------------------
header "Step 2 — Add Power tab to nav rail"

add_power_tab() {
    local file="$1"
    if [ ! -f "$file" ]; then return; fi
    if grep -q 'href="/power.html"' "$file"; then
        ok "Power tab already in $file"
        return
    fi
    # Insert Power tab before closing </nav>
    sed -i 's|</nav>|  <div class="tab-divider"></div>\n  <a class="tab" href="/power.html">Power</a>\n</nav>|' "$file"
    ok "Added Power tab to $file"
}

add_power_tab "$WEB_ROOT/index.html"
add_power_tab "$WEB_ROOT/devices.html"
add_power_tab "$WEB_ROOT/mqtt.html"

# ---------------------------------------------------------------------------
# Install power-api.py
# ---------------------------------------------------------------------------
header "Step 3 — Install power-api.py"
mkdir -p "$OPT_DIR"
install -m 755 "$REPO_DIR/power-api.py" "$OPT_DIR/power-api.py"
ok "Installed: $OPT_DIR/power-api.py"

# ---------------------------------------------------------------------------
# Add threshold key to ups.conf
# ---------------------------------------------------------------------------
header "Step 4 — Add UPS_SHUTDOWN_THRESHOLD to ups.conf"
if grep -q "UPS_SHUTDOWN_THRESHOLD" "$CONF_FILE" 2>/dev/null; then
    ok "UPS_SHUTDOWN_THRESHOLD already in ups.conf"
else
    echo "UPS_SHUTDOWN_THRESHOLD=15" >> "$CONF_FILE"
    ok "Added UPS_SHUTDOWN_THRESHOLD=15 to ups.conf"
fi

# ---------------------------------------------------------------------------
# Update nginx snippet to add power API proxy routes
# ---------------------------------------------------------------------------
header "Step 5 — Update nginx snippet"

SNIPPET=/etc/nginx/snippets/cyberdeck-ups.conf
cat > "$SNIPPET" <<'NGINXEOF'
# cyberdeck-ups.conf — UPS status and power management API routes

# Live UPS telemetry from the daemon
location /ups-status.json {
    alias /run/cyberdeck-pi4/ups-status.json;
    default_type application/json;
    add_header Cache-Control "no-cache, no-store";
    add_header Access-Control-Allow-Origin "*";
}

# Power management API (proxied to power-api.py on port 8081)
location /api/lowpower {
    proxy_pass http://127.0.0.1:8081/api/lowpower;
    proxy_method POST;
    proxy_set_header Content-Type application/json;
}

location /api/ups/ {
    proxy_pass http://127.0.0.1:8081/api/ups/;
    proxy_set_header Content-Type application/json;
}
NGINXEOF
ok "Updated: $SNIPPET"

nginx -t && systemctl reload nginx && ok "nginx reloaded"

# ---------------------------------------------------------------------------
# Install and start the service
# ---------------------------------------------------------------------------
header "Step 6 — Enable cyberdeck-power-api.service"
install -m 644 "$REPO_DIR/../config/cyberdeck-power-api.service" \
               /etc/systemd/system/cyberdeck-power-api.service
systemctl daemon-reload
systemctl enable --now cyberdeck-power-api
sleep 2
if systemctl is-active --quiet cyberdeck-power-api; then
    ok "cyberdeck-power-api.service running"
else
    warn "Service may not have started — check: sudo systemctl status cyberdeck-power-api"
fi

# ---------------------------------------------------------------------------
# Also restart UPS daemon so it picks up the new threshold key
# ---------------------------------------------------------------------------
systemctl restart cyberdeck-ups && ok "cyberdeck-ups restarted to pick up threshold config"

header "Installation complete"
echo ""
echo "  Power page: http://cyberdeck-pi4.local/power.html"
echo "  API test:   curl http://localhost:8081/api/ups/threshold"
echo ""
