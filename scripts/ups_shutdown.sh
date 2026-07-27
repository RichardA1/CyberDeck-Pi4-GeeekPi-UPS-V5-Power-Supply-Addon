#!/bin/bash
# ups_shutdown.sh — UPS-aware shutdown for CyberDeck Pi4
#
# Triggers the GeeekPi UPS V5 20-second power cutoff countdown via I2C,
# then halts the Pi cleanly. The UPS cuts board power ~18 seconds after
# the Pi OS has halted.
#
# Called by:
#   - TFT button daemon (via SHUTDOWN_CMD in /etc/cyberdeck-pi4/tft.conf)
#   - Web UI shutdown endpoint (via nginx + shell exec)
#
# Usage: sudo /opt/cyberdeck-pi4/scripts/ups_shutdown.sh

set -e

CONF=/etc/cyberdeck-pi4/ups.conf
UPS_BUS=1
UPS_ADDR=0x17
UPS_SHUTDOWN_DELAY=20

# Load config overrides if present
if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

LOG_TAG="cyberdeck-ups-shutdown"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%H:%M:%S')] $1"
}

log "UPS shutdown initiated"

# Verify i2c-tools is available
if ! command -v i2cset >/dev/null 2>&1; then
    log "ERROR: i2cset not found — install i2c-tools"
    exit 1
fi

# Verify the UPS is on the bus before writing to it
if ! i2cget -y "$UPS_BUS" "$UPS_ADDR" 0x17 >/dev/null 2>&1; then
    log "WARNING: UPS not responding at address $UPS_ADDR on bus $UPS_BUS — falling back to OS shutdown only"
    /sbin/shutdown -h now
    exit 0
fi

# Write the shutdown countdown register (0x18)
log "Writing ${UPS_SHUTDOWN_DELAY}s countdown to UPS register 0x18"
i2cset -y "$UPS_BUS" "$UPS_ADDR" 0x18 "$UPS_SHUTDOWN_DELAY"

# Brief pause to ensure the I2C write completes before we pull the rug
sleep 2

log "Halting Pi OS — UPS will cut power in ~${UPS_SHUTDOWN_DELAY}s"
/sbin/shutdown -h now
