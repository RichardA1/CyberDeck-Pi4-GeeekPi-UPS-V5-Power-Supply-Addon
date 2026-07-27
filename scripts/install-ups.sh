#!/bin/bash
# install-ups.sh — CyberDeck Pi4 GeeekPi UPS V5 Addon Installer
#
# What this script does:
#   1. Enables I2C via raspi-config
#   2. Fixes dtparam=i2c_arm=off in /boot/firmware/config.txt if the
#      Adafruit PiTFT helper wrote it (a known conflict)
#   3. Installs i2c-tools and python3-smbus2 if missing
#   4. Verifies the UPS is visible at 0x17 on I2C bus 1
#   5. Installs ups_shutdown.sh to /opt/cyberdeck-pi4/scripts/
#   6. Installs ups_daemon.py to /opt/cyberdeck-pi4/ups/
#   7. Installs ups.conf to /etc/cyberdeck-pi4/
#   8. Updates SHUTDOWN_CMD in /etc/cyberdeck-pi4/tft.conf
#   9. Patches the web UI nginx config to serve /ups-status.json
#  10. Enables and starts cyberdeck-ups.service
#
# Usage: sudo ./scripts/install-ups.sh

set -e

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${AMBER}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

REBOOT_NEEDED=0

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || error "Run with sudo: sudo ./scripts/install-ups.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

header "CyberDeck Pi4 — UPS V5 Addon Installer"
echo ""
echo "  Repo:    $REPO_DIR"
echo "  Target:  /opt/cyberdeck-pi4/ups/"
echo "  Config:  /etc/cyberdeck-pi4/ups.conf"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Enable I2C
# ---------------------------------------------------------------------------
header "Step 1 — Enable I2C"

if ls /dev/i2c-1 >/dev/null 2>&1; then
    ok "/dev/i2c-1 already exists — I2C enabled"
else
    info "Enabling I2C via raspi-config..."
    raspi-config nonint do_i2c 0
    ok "I2C enabled"
    REBOOT_NEEDED=1
fi

# ---------------------------------------------------------------------------
# Step 2 — Fix PiTFT i2c_arm=off conflict in config.txt
# ---------------------------------------------------------------------------
header "Step 2 — Check /boot/firmware/config.txt for i2c_arm conflict"

CONFIG_TXT=/boot/firmware/config.txt
[ -f "$CONFIG_TXT" ] || CONFIG_TXT=/boot/config.txt
[ -f "$CONFIG_TXT" ] || error "Cannot find config.txt at /boot/firmware/config.txt or /boot/config.txt"

# Check if the Adafruit PiTFT helper wrote i2c_arm=off
if grep -q "dtparam=i2c_arm=off" "$CONFIG_TXT"; then
    warn "Found dtparam=i2c_arm=off in $CONFIG_TXT (written by Adafruit PiTFT helper)"
    info "Replacing all occurrences of dtparam=i2c_arm=off with dtparam=i2c_arm=on..."
    # Use sed to fix in place — replace every occurrence
    sed -i 's/dtparam=i2c_arm=off/dtparam=i2c_arm=on/g' "$CONFIG_TXT"
    ok "Fixed: dtparam=i2c_arm=off → dtparam=i2c_arm=on"
    REBOOT_NEEDED=1
else
    ok "No i2c_arm=off conflict found"
fi

# ---------------------------------------------------------------------------
# Step 3 — Install dependencies
# ---------------------------------------------------------------------------
header "Step 3 — Install dependencies"

PKGS_NEEDED=()
command -v i2cdetect >/dev/null 2>&1 || PKGS_NEEDED+=(i2c-tools)
python3 -c "import smbus2" 2>/dev/null    || PKGS_NEEDED+=(python3-smbus2)

if [ ${#PKGS_NEEDED[@]} -gt 0 ]; then
    info "Installing: ${PKGS_NEEDED[*]}"
    apt-get install -y "${PKGS_NEEDED[@]}"
    ok "Dependencies installed"
else
    ok "All dependencies already present"
fi

# ---------------------------------------------------------------------------
# Step 4 — Verify UPS is on the bus (skip if reboot needed)
# ---------------------------------------------------------------------------
header "Step 4 — Verify UPS at I2C address 0x17"

if [ "$REBOOT_NEEDED" -eq 1 ]; then
    warn "Skipping I2C verification — a reboot is required first"
    warn "After rebooting, re-run this installer to complete steps 4-10"
else
    if ls /dev/i2c-1 >/dev/null 2>&1; then
        if i2cget -y 1 0x17 0x17 >/dev/null 2>&1; then
            POGO_LO=$(i2cget -y 1 0x17 0x03 2>/dev/null | xargs printf "%d" || echo 0)
            POGO_HI=$(i2cget -y 1 0x17 0x04 2>/dev/null | xargs printf "%d" || echo 0)
            POGO_MV=$(( POGO_LO | (POGO_HI << 8) ))
            ok "UPS found at 0x17 — Pogopin voltage: ${POGO_MV}mV"
            if [ "$POGO_MV" -eq 0 ]; then
                warn "Pogopin voltage is 0 mV — UPS firmware may need updating."
                warn "See README.md — 'Before You Install' section for OTA update steps."
            fi
        else
            error "UPS not found at 0x17 on I2C bus 1.\n  Check: HAT is seated, batteries are installed, i2c_arm=on in config.txt.\n  See README.md troubleshooting section."
        fi
    else
        warn "I2C bus not yet available — reboot and re-run to complete verification"
        REBOOT_NEEDED=1
    fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Install ups_shutdown.sh
# ---------------------------------------------------------------------------
header "Step 5 — Install ups_shutdown.sh"

install -d /opt/cyberdeck-pi4/scripts
install -m 755 "$REPO_DIR/scripts/ups_shutdown.sh" /opt/cyberdeck-pi4/scripts/ups_shutdown.sh
ok "Installed: /opt/cyberdeck-pi4/scripts/ups_shutdown.sh"

# ---------------------------------------------------------------------------
# Step 6 — Install ups_daemon.py
# ---------------------------------------------------------------------------
header "Step 6 — Install ups_daemon.py"

install -d /opt/cyberdeck-pi4/ups
install -m 755 "$REPO_DIR/scripts/ups_daemon.py" /opt/cyberdeck-pi4/ups/ups_daemon.py
ok "Installed: /opt/cyberdeck-pi4/ups/ups_daemon.py"

# ---------------------------------------------------------------------------
# Step 7 — Install ups.conf
# ---------------------------------------------------------------------------
header "Step 7 — Install ups.conf"

install -d /etc/cyberdeck-pi4
if [ -f /etc/cyberdeck-pi4/ups.conf ]; then
    warn "ups.conf already exists — leaving existing config in place"
    info "Reference config at: $REPO_DIR/config/ups.conf"
else
    install -m 644 "$REPO_DIR/config/ups.conf" /etc/cyberdeck-pi4/ups.conf
    ok "Installed: /etc/cyberdeck-pi4/ups.conf"
fi

# ---------------------------------------------------------------------------
# Step 8 — Update SHUTDOWN_CMD in tft.conf
# ---------------------------------------------------------------------------
header "Step 8 — Update SHUTDOWN_CMD in tft.conf"

TFT_CONF=/etc/cyberdeck-pi4/tft.conf

if [ -f "$TFT_CONF" ]; then
    # Back up original
    if [ ! -f "${TFT_CONF}.pre-ups" ]; then
        cp "$TFT_CONF" "${TFT_CONF}.pre-ups"
        info "Backed up original tft.conf to tft.conf.pre-ups"
    fi

    OLD_CMD=$(grep "^SHUTDOWN_CMD=" "$TFT_CONF" || true)
    if echo "$OLD_CMD" | grep -q "ups_shutdown"; then
        ok "SHUTDOWN_CMD already points to ups_shutdown.sh — no change needed"
    else
        sed -i 's|^SHUTDOWN_CMD=.*|SHUTDOWN_CMD="/opt/cyberdeck-pi4/scripts/ups_shutdown.sh"|' "$TFT_CONF"
        ok "Updated SHUTDOWN_CMD in tft.conf"
        info "Old value: $OLD_CMD"
        info "New value: SHUTDOWN_CMD=\"/opt/cyberdeck-pi4/scripts/ups_shutdown.sh\""
    fi

    # Append UPS config block if not already present
    if ! grep -q "UPS_I2C_BUS" "$TFT_CONF"; then
        cat >> "$TFT_CONF" <<'EOF'

# --- UPS addon (added by install-ups.sh) ---
UPS_I2C_BUS=1
UPS_I2C_ADDR=0x17
UPS_SHUTDOWN_DELAY=20
UPS_POLL_SEC=30
EOF
        ok "Appended UPS config keys to tft.conf"
    fi
else
    warn "tft.conf not found at $TFT_CONF — skipping (TFT addon may not be installed)"
fi

# ---------------------------------------------------------------------------
# Step 9 — Patch nginx to serve /ups-status.json
# ---------------------------------------------------------------------------
header "Step 9 — Patch nginx for /ups-status.json and web UI shutdown"

NGINX_CYBERDECK_CONF=""
for candidate in /etc/nginx/sites-enabled/cyberdeck \
                 /etc/nginx/sites-enabled/cyberdeck-pi4 \
                 /etc/nginx/conf.d/cyberdeck.conf; do
    [ -f "$candidate" ] && NGINX_CYBERDECK_CONF="$candidate" && break
done

NGINX_SNIPPET=/etc/nginx/snippets/cyberdeck-ups.conf
cat > "$NGINX_SNIPPET" <<'NGINXEOF'
# cyberdeck-ups.conf — included by the main cyberdeck nginx server block
# Serves UPS status JSON and handles the web UI UPS-aware shutdown.
# Added by install-ups.sh

# Serve live UPS telemetry from the daemon's runtime file
location /ups-status.json {
    alias /run/cyberdeck-pi4/ups-status.json;
    default_type application/json;
    add_header Cache-Control "no-cache, no-store";
    add_header Access-Control-Allow-Origin "*";
}

# Web UI shutdown — calls ups_shutdown.sh via sudo
# Requires the www-data sudoers entry installed by this script
location /api/shutdown {
    content_by_lua_block {
        os.execute("sudo /opt/cyberdeck-pi4/scripts/ups_shutdown.sh &")
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"status":"shutdown_initiated"}')
    }
}
NGINXEOF
ok "Written: $NGINX_SNIPPET"

# Add sudoers entry so www-data can call ups_shutdown.sh without a password
SUDOERS_FILE=/etc/sudoers.d/cyberdeck-ups
cat > "$SUDOERS_FILE" <<'SUDOEOF'
# Allow the nginx worker (www-data) to call the UPS shutdown script
www-data ALL=(root) NOPASSWD: /opt/cyberdeck-pi4/scripts/ups_shutdown.sh
SUDOEOF
chmod 440 "$SUDOERS_FILE"
ok "Written: $SUDOERS_FILE"

if [ -n "$NGINX_CYBERDECK_CONF" ]; then
    if ! grep -q "cyberdeck-ups.conf" "$NGINX_CYBERDECK_CONF"; then
        # Insert include before the closing brace of the server block
        sed -i '/^}/i\    include snippets/cyberdeck-ups.conf;' "$NGINX_CYBERDECK_CONF"
        ok "Added include to $NGINX_CYBERDECK_CONF"
        nginx -t && systemctl reload nginx && ok "nginx reloaded"
    else
        ok "nginx already includes cyberdeck-ups.conf — no change needed"
    fi
else
    warn "Could not find CyberDeck nginx config — snippet written but not included automatically."
    warn "Add this line to your nginx server block manually:"
    warn "    include snippets/cyberdeck-ups.conf;"
fi

# ---------------------------------------------------------------------------
# Step 10 — Install and start the systemd service
# ---------------------------------------------------------------------------
header "Step 10 — Enable cyberdeck-ups.service"

install -m 644 "$REPO_DIR/config/cyberdeck-ups.service" \
               /etc/systemd/system/cyberdeck-ups.service
systemctl daemon-reload

if [ "$REBOOT_NEEDED" -eq 0 ]; then
    systemctl enable --now cyberdeck-ups
    ok "cyberdeck-ups.service enabled and started"
    sleep 2
    if systemctl is-active --quiet cyberdeck-ups; then
        ok "Daemon is running"
    else
        warn "Daemon may not have started yet — check: sudo systemctl status cyberdeck-ups"
    fi
else
    systemctl enable cyberdeck-ups
    ok "cyberdeck-ups.service enabled (will start after reboot)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
header "Installation complete"

if [ "$REBOOT_NEEDED" -eq 1 ]; then
    echo ""
    echo -e "${AMBER}  *** REBOOT REQUIRED ***${NC}"
    echo ""
    echo "  I2C was enabled or config.txt was modified."
    echo "  After rebooting, re-run this installer to complete the setup:"
    echo ""
    echo "    sudo reboot"
    echo "    sudo ./scripts/install-ups.sh"
    echo ""
else
    echo ""
    echo "  All steps complete. Quick verification:"
    echo ""
    echo "    sudo systemctl status cyberdeck-ups"
    echo "    cat /run/cyberdeck-pi4/battery.json"
    echo "    cat /run/cyberdeck-pi4/ups-status.json"
    echo ""
    echo "  TFT panel will pick up battery data on its next refresh."
    echo "  Web UI /ups-status.json is now live."
    echo ""
fi
