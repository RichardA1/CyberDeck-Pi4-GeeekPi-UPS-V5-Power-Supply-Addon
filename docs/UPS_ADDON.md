# CyberDeck Pi4 — UPS V5 Addon Technical Reference

This document covers the full technical detail of the GeeekPi UPS V5 addon for the
CyberDeck Pi4 project. For quick install steps see the top-level `README.md`.

---

## 1. Hardware

### 1.1 UPS HAT

**Model:** GeeekPi UPS Plus V5 (EP-0136)  
**I2C address:** `0x17` (factory default after firmware update)  
**I2C bus:** 1 (GPIO pins 2 and 3 on the Pi 40-pin header)  
**Batteries:** 2× 18650 lithium cells (4.2V / 4.35V / 4.4V / 4.5V chemistry)  
**Charging input:** USB-C (preferred) or MicroUSB  
**Temperature cutoff:** 65°C (hardware enforced, cannot be disabled)

> ⚠️ Do not mix battery chemistry types. Do not plug a charger into the Pi's own USB-C
> port while the UPS is in use.

### 1.2 GPIO usage

The UPS HAT uses only I2C (GPIO 2/3 = SDA/SCL). It does not claim any additional GPIO
pins, so there is no conflict with the TFT panel addon's buttons (GPIO 17, 22, 23, 27)
or backlight (GPIO 18).

### 1.3 I2C bus conflict with PiTFT

The Adafruit PiTFT 2.8" helper script (`adafruit-pitft.py`) appends a configuration
block to `/boot/firmware/config.txt` that includes `dtparam=i2c_arm=off`. Since this
block appears at the bottom of the file it overrides any earlier `i2c_arm=on` setting.

The installer detects and corrects this automatically. If you reinstall the PiTFT helper
after installing this addon, re-run `install-ups.sh` to fix the conflict again.

The PiTFT uses SPI for its display — `i2c_arm=on` does not affect it.

---

## 2. Register Map

Full GeeekPi UPS V5 register map for reference. All multi-byte values are
little-endian (low byte first).

| Address | Function | Range | Unit | R/W |
|---|---|---|---|---|
| `0x01–0x02` | MCU voltage | 2400–3600 | mV | RO |
| `0x03–0x04` | Pogopin / 5V output voltage | 0–5500 | mV | RO |
| `0x05–0x06` | Battery terminal voltage | 0–4500 | mV | RO |
| `0x07–0x08` | USB-C charge port voltage | 0–13500 | mV | RO |
| `0x09–0x0A` | MicroUSB charge port voltage | 0–13500 | mV | RO |
| `0x0B–0x0C` | Battery temperature | -20–65 | °C | RO |
| `0x0D–0x0E` | Full voltage threshold | 0–4500 | mV | RW |
| `0x0F–0x10` | Empty voltage threshold | 0–4500 | mV | RW |
| `0x11–0x12` | Protection voltage | 0–4500 | mV | RW |
| `0x13–0x14` | Battery remaining | 0–100 | % | RO |
| `0x15–0x16` | Sample period | 1–1440 | min | RW |
| `0x17` | Power status / operation mode | 0/1 | bool | RO |
| `0x18` | Shutdown countdown | 0 / 10–255 | sec | RW |
| `0x19` | Back-To-AC auto power-up | 0/1 | bool | RW |
| `0x1A` | Restart countdown | 0 / 10–255 | sec | RW |
| `0x1B` | Reset to factory defaults | 0/1 | bool | RW |
| `0x1C–0x1F` | Cumulative running time | 0–2147483647 | sec | RO |
| `0x20–0x23` | Accumulated charging time | 0–2147483647 | sec | RO |
| `0x24–0x27` | Running time | 0–2147483647 | sec | RO |
| `0x28–0x29` | Firmware version | fixed | — | RO |
| `0xF0–0xFB` | Serial number (device UID) | fixed | ASCII | RO |

### Shutdown countdown register (`0x18`)

Writing a value of 10–255 to this register starts a countdown. When the countdown
expires the UPS cuts power to the board regardless of what the Pi is doing.

**Important:** This register is not a hardware timer. It requires an active daemon or
script to write the value. Once written, the UPS V5 acts on it independently — you do
not need to keep polling after the write. The countdown runs in UPS firmware.

Writing `0` cancels a pending countdown.

---

## 3. Shutdown Integration

### 3.1 ups_shutdown.sh

Installed to `/opt/cyberdeck-pi4/scripts/ups_shutdown.sh`.

```
i2cset -y 1 0x17 0x18 20   ← write 20s countdown to UPS
sleep 2                     ← let I2C write settle
shutdown -h now             ← halt Pi OS cleanly
                            ← ~18s later: UPS cuts board power
```

### 3.2 TFT shutdown button

`/etc/cyberdeck-pi4/tft.conf` `SHUTDOWN_CMD` is updated by the installer:

```ini
SHUTDOWN_CMD="/opt/cyberdeck-pi4/scripts/ups_shutdown.sh"
```

The TFT button daemon's `act_shutdown()` calls `subprocess.Popen(SHUTDOWN_CMD, shell=True)`
— no changes to `button_daemon.py` are required.

### 3.3 Web UI shutdown button

The web UI calls `POST /api/shutdown`. The nginx snippet installed at
`/etc/nginx/snippets/cyberdeck-ups.conf` handles this endpoint by calling
`ups_shutdown.sh` via sudo (the `www-data` sudoers entry permits this without a
password).

The web UI button should fire a `fetch('/api/shutdown', {method: 'POST'})` — the
response `{"status":"shutdown_initiated"}` arrives before the Pi begins halting,
giving the browser time to show a shutdown confirmation screen.

---

## 4. Battery Telemetry

### 4.1 Daemon output files

`ups_daemon.py` writes two files every `UPS_POLL_SEC` seconds (default 30):

**`/run/cyberdeck-pi4/battery.json`** — TFT panel contract:
```json
{"percent": 99, "charging": true, "volts": 3.982}
```

**`/run/cyberdeck-pi4/ups-status.json`** — full status blob:
```json
{
  "available": true,
  "pi": {
    "voltage": 4.807,
    "voltage_mv": 4807,
    "voltage_health": "good"
  },
  "battery": {
    "voltage": 3.982,
    "voltage_mv": 3982,
    "percent": 99,
    "charging": true,
    "status": "CHARGING",
    "health": "good",
    "charge_source": "usb-c"
  },
  "mcu": {
    "voltage_mv": 3240,
    "temp_c": 54,
    "power_status": 1,
    "back_to_ac": false,
    "shutdown_countdown": 0
  },
  "charge_ports": {
    "usbc_mv": 4468,
    "musb_mv": 12
  },
  "timestamp": 1753123456
}
```

### 4.2 TFT panel integration

The TFT panel addon's `battery.py` already reads `/run/cyberdeck-pi4/battery.json`
via its `BATTERY_FILE` constant. No changes to the panel code are needed — fitting
the UPS addon was the original design intent of the placeholder.

### 4.3 Web UI integration

The `/ups-status.json` endpoint is served by nginx directly from the daemon's runtime
file. The web UI battery widget should `fetch('/ups-status.json')` and render the
`battery.percent`, `battery.status`, and `battery.voltage` fields.

### 4.4 Battery calibration

The `percent` reading requires at least one complete charge/discharge cycle to
calibrate. Until then it may read 0% or an inaccurate value even with healthy batteries
installed. Run the deck on battery until the UPS shuts it down, then charge fully,
and the percentage will become accurate.

---

## 5. Known Issues and Gotchas

### Firmware freeze (all registers read zero)

Affects roughly 0.8% of units. Symptoms: UPS visible on I2C at `0x17` but all voltage
and battery registers return 0. Fix: OTA firmware update via the GeeekPi repo (see
README.md). After update the device resets to address `0x17`.

### Corrupted firmware causes address shift to `0x18`

A corrupted UPS firmware can cause the device to respond at `0x18` instead of `0x17`.
This is a symptom of the same firmware issue above. OTA update and full power cycle
(disconnect charger, remove batteries, re-insert batteries, reconnect charger, press
power button) restores the correct `0x17` address.

### PiTFT helper overwrites i2c_arm=on

If the Adafruit PiTFT helper is run after this addon is installed, it will append
`dtparam=i2c_arm=off` to `config.txt` again. Re-run `install-ups.sh` to fix, or
manually change the line in the Adafruit block at the bottom of `config.txt`.

### Battery percentage requires calibration cycle

See §4.4. A freshly installed UPS with no prior charge/discharge history will report
0% until calibrated.

### Long-term storage

If the CyberDeck will not be used for more than a week, remove the batteries from the
UPS. The UPS cannot fully power off with batteries installed and will slowly drain them.

---

## 6. Acceptance Checklist

- [ ] `sudo i2cdetect -y 1` shows UPS at `0x17`
- [ ] Register dump returns non-zero voltages (see README quick test)
- [ ] `ups_shutdown.sh` triggers UPS countdown and Pi halts cleanly
- [ ] UPS cuts board power ~20 seconds after halt
- [ ] Pi restarts correctly after power restore (manual button or Back-To-AC)
- [ ] `cyberdeck-ups.service` starts on boot
- [ ] `/run/cyberdeck-pi4/battery.json` is written within 30s of boot
- [ ] TFT panel battery indicator shows real percentage (not `NO SENSOR`)
- [ ] `/ups-status.json` returns valid JSON via HTTP
- [ ] Web UI shutdown button triggers UPS countdown path
- [ ] TFT shutdown button (3s hold) triggers UPS countdown path
- [ ] Uninstaller cleanly removes all files and restores tft.conf
