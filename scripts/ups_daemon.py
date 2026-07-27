#!/usr/bin/env python3
"""
ups_daemon.py — GeeekPi UPS V5 polling daemon for CyberDeck Pi4.

Reads UPS registers over I2C every UPS_POLL_SEC seconds and writes
two output files:

  /run/cyberdeck-pi4/battery.json   — consumed by the TFT panel's battery.py
  /run/cyberdeck-pi4/ups-status.json — served by nginx as /ups-status.json

The TFT panel already reads battery.json via its placeholder battery.py —
no changes to panel code are required.

Register map (GeeekPi UPS Plus V5, device address 0x17):
  0x01-0x02  MCU voltage (mV)
  0x03-0x04  Pogopin / 5V output voltage (mV)
  0x05-0x06  Battery terminal voltage (mV)
  0x07-0x08  USB-C charge port voltage (mV)
  0x09-0x0A  MicroUSB charge port voltage (mV)
  0x0B-0x0C  Battery temperature (°C)
  0x13-0x14  Battery remaining (%)
  0x17       Power status (1=on)
  0x18       Shutdown countdown (RW)
  0x19       Back-To-AC auto power-up (RW)
"""

import json
import logging
import os
import signal
import sys
import time

try:
    import smbus2
except ImportError:
    print("ERROR: smbus2 not found. Install with: sudo apt install python3-smbus2")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Configuration — overridden by /etc/cyberdeck-pi4/ups.conf if present
# ---------------------------------------------------------------------------
CONF_FILE    = "/etc/cyberdeck-pi4/ups.conf"
UPS_BUS      = 1
UPS_ADDR     = 0x17
POLL_SEC     = 30
RUN_DIR      = "/run/cyberdeck-pi4"
BATTERY_FILE = os.path.join(RUN_DIR, "battery.json")
STATUS_FILE  = os.path.join(RUN_DIR, "ups-status.json")

def _load_conf():
    global UPS_BUS, UPS_ADDR, POLL_SEC
    if not os.path.exists(CONF_FILE):
        return
    with open(CONF_FILE) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key == "UPS_I2C_BUS":
                UPS_BUS = int(val)
            elif key == "UPS_I2C_ADDR":
                UPS_ADDR = int(val, 16) if val.startswith("0x") else int(val)
            elif key == "UPS_POLL_SEC":
                POLL_SEC = int(val)

_load_conf()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("cyberdeck-ups")

# ---------------------------------------------------------------------------
# Stop flag
# ---------------------------------------------------------------------------
_stop = False

def _handle_signal(signum, _frame):
    global _stop
    log.info("signal %s — stopping", signum)
    _stop = True

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT,  _handle_signal)

# ---------------------------------------------------------------------------
# I2C helpers
# ---------------------------------------------------------------------------
def read16(bus, addr, reg):
    """Read a 16-bit little-endian value from two consecutive registers."""
    lo = bus.read_byte_data(addr, reg)
    hi = bus.read_byte_data(addr, reg + 1)
    return lo | (hi << 8)

def read8(bus, addr, reg):
    return bus.read_byte_data(addr, reg)

# ---------------------------------------------------------------------------
# UPS read
# ---------------------------------------------------------------------------
def read_ups(bus):
    """
    Read all relevant UPS registers.
    Returns a dict on success, None on any I2C error.
    """
    try:
        mcu_mv      = read16(bus, UPS_ADDR, 0x01)
        pogo_mv     = read16(bus, UPS_ADDR, 0x03)
        batt_mv     = read16(bus, UPS_ADDR, 0x05)
        usbc_mv     = read16(bus, UPS_ADDR, 0x07)
        musb_mv     = read16(bus, UPS_ADDR, 0x09)
        temp_c      = read16(bus, UPS_ADDR, 0x0B)
        batt_pct    = read16(bus, UPS_ADDR, 0x13)
        pwr_status  = read8(bus,  UPS_ADDR, 0x17)
        shutdown_cd = read8(bus,  UPS_ADDR, 0x18)
        back_to_ac  = read8(bus,  UPS_ADDR, 0x19)

        # Determine charging source
        charging = False
        charge_source = "none"
        if usbc_mv > 1000:
            charging = True
            charge_source = "usb-c"
        elif musb_mv > 1000:
            charging = True
            charge_source = "microusb"

        # Voltage health thresholds
        def voltage_health(mv):
            if mv >= 4750:
                return "good"
            elif mv >= 4500:
                return "warning"
            return "low"

        return {
            "available": True,
            "pi": {
                "voltage":        round(pogo_mv / 1000, 3),
                "voltage_mv":     pogo_mv,
                "voltage_health": voltage_health(pogo_mv),
            },
            "battery": {
                "voltage":    round(batt_mv / 1000, 3),
                "voltage_mv": batt_mv,
                "percent":    max(0, min(100, batt_pct)),
                "charging":   charging,
                "status":     "CHARGING" if charging else "DISCHARGING",
                "health":     "good" if batt_mv > 3500 else "low",
                "charge_source": charge_source,
            },
            "mcu": {
                "voltage_mv": mcu_mv,
                "temp_c":     temp_c,
                "power_status": pwr_status,
                "back_to_ac": bool(back_to_ac),
                "shutdown_countdown": shutdown_cd,
            },
            "charge_ports": {
                "usbc_mv":  usbc_mv,
                "musb_mv":  musb_mv,
            },
            "timestamp": int(time.time()),
        }
    except OSError as exc:
        log.warning("I2C read failed: %s", exc)
        return None

# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------
def write_battery_json(data):
    """
    Write the TFT panel battery.py contract:
      {"percent": 0..100, "charging": bool, "volts": float}
    """
    os.makedirs(RUN_DIR, exist_ok=True)
    payload = {
        "percent":  data["battery"]["percent"],
        "charging": data["battery"]["charging"],
        "volts":    data["battery"]["voltage"],
    }
    _atomic_write(BATTERY_FILE, json.dumps(payload))

def write_status_json(data):
    """Write the full status blob served as /ups-status.json by nginx."""
    os.makedirs(RUN_DIR, exist_ok=True)
    _atomic_write(STATUS_FILE, json.dumps(data, indent=2))

def write_unavailable():
    """Write fallback files when the UPS is not responding."""
    os.makedirs(RUN_DIR, exist_ok=True)
    _atomic_write(BATTERY_FILE, "null")
    _atomic_write(STATUS_FILE, json.dumps({"available": False,
                                            "timestamp": int(time.time())}, indent=2))

def _atomic_write(path, content):
    """Write via a temp file and rename to avoid partial reads."""
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.replace(tmp, path)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
def main():
    log.info("CyberDeck UPS daemon starting (bus=%d addr=0x%02x poll=%ds)",
             UPS_BUS, UPS_ADDR, POLL_SEC)

    try:
        bus = smbus2.SMBus(UPS_BUS)
    except Exception as exc:
        log.error("Cannot open I2C bus %d: %s", UPS_BUS, exc)
        sys.exit(1)

    consecutive_failures = 0

    while not _stop:
        data = read_ups(bus)

        if data is None:
            consecutive_failures += 1
            log.warning("UPS read failed (failure #%d)", consecutive_failures)
            if consecutive_failures >= 3:
                log.error("UPS unresponsive — writing unavailable state")
                write_unavailable()
        else:
            consecutive_failures = 0
            write_battery_json(data)
            write_status_json(data)
            log.info(
                "UPS OK — battery %d%% %s | Pi %.2fV | Batt %.3fV | Temp %d°C",
                data["battery"]["percent"],
                data["battery"]["status"],
                data["pi"]["voltage"],
                data["battery"]["voltage"],
                data["mcu"]["temp_c"],
            )

        # Sleep in short increments so SIGTERM is handled promptly
        for _ in range(POLL_SEC * 2):
            if _stop:
                break
            time.sleep(0.5)

    log.info("UPS daemon stopped")
    write_unavailable()

if __name__ == "__main__":
    main()
