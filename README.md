# CyberDeck Pi4 — GeeekPi UPS V5 Power Supply Addon

Addon for the [CyberDeck Pi4](https://github.com/your-org/cyberdeck-pi4) project.
Integrates the GeeekPi UPS Plus V5 HAT (EP-0136) with the CyberDeck stack: UPS-aware
shutdown, live battery telemetry on the TFT panel and web UI, and a polling daemon that
bridges the UPS over I2C to the rest of the system.

<img width="397" height="293" alt="TFT Display" src="https://github.com/user-attachments/assets/ad275c0c-94ab-4c85-a2d7-14420e6147a4" />

<img width="725" height="582" alt="AP Web Power Pannel" src="https://github.com/user-attachments/assets/0536bdbe-c3b9-4184-b0d2-52baa8d0591a" />

---

> ⚠️ **DO NOT plug a power supply into the Raspberry Pi's own USB-C port while the UPS
> HAT is in use. This can damage the UPS. Charge through the UPS HAT's USB-C or MicroUSB
> port only.**

---

## Before You Install — Check and Update UPS Firmware

The UPS V5 ships with firmware that can become corrupted or outdated. A frozen firmware
causes all I2C registers to read zero even with batteries installed. **Check and update
firmware before running the installer.**

### Check current firmware version

```bash
sudo i2cdetect -y 1
```

The UPS should appear at address `0x17`. If it shows at `0x18` or all registers read zero,
the firmware needs updating.

Read the firmware version register:

```bash
python3 - <<'EOF'
import smbus2
bus = smbus2.SMBus(1)
lo = bus.read_byte_data(0x17, 0x28)
hi = bus.read_byte_data(0x17, 0x29)
print(f"UPS firmware version registers: 0x28={lo} 0x29={hi}")
# Also confirm device is responding with a real voltage
volts = bus.read_byte_data(0x17, 0x03) | (bus.read_byte_data(0x17, 0x04) << 8)
print(f"Pogopin voltage (should be ~4800-5000): {volts} mV")
EOF
```

If the voltage reads `0` with batteries installed and charging connected, proceed to the
firmware update below.

### Update UPS firmware (OTA)

The Pi must have internet access for this step.

```bash
# Install smbus2 if not already present
sudo apt install -y python3-smbus2

# Clone the GeeekPi UPS repository
cd ~
git clone https://github.com/geeekpi/upsplus.git
cd upsplus/

# Run the OTA upgrade
python3 OTA_firmware_upgrade.py
```

> ⚠️ **Do not power off or disconnect the network during the upgrade.** The Pi will shut
> down automatically when the upgrade completes.

After the Pi shuts down:

1. Disconnect the USB-C charging cable from the UPS
2. Remove the batteries from the UPS
3. Re-insert the batteries
4. Reconnect the USB-C charging cable
5. Press the UPS power button to restart

After reboot, verify the UPS is now at `0x17` and registers return real data:

```bash
sudo i2cdetect -y 1   # should show 0x17
sudo i2cget -y 1 0x17 0x03   # pogopin voltage low byte — should be non-zero
```

---

## What This Addon Adds

- **`ups_shutdown.sh`** — UPS-aware shutdown script. Triggers the UPS 20-second power
  cutoff countdown via I2C, then halts the Pi cleanly. Used by both the TFT button daemon
  and the web UI.
- **`ups_daemon.py`** — Polling daemon. Reads UPS registers every 30 seconds and writes
  `/run/cyberdeck-pi4/battery.json` so the TFT panel's existing battery placeholder
  lights up with real data automatically.
- **`install-ups.sh`** — Installer. Enables I2C, fixes the PiTFT `i2c_arm=off` conflict,
  installs the daemon and scripts, updates `tft.conf` to use `ups_shutdown.sh`, patches
  the web UI shutdown endpoint, and starts the daemon service.
- **`uninstall-ups.sh`** — Clean removal. Restores all modified files to their pre-addon
  state.
- **`cyberdeck-ups.service`** — systemd unit for the polling daemon.
- **`ci-ups.yml`** — GitHub Actions CI: shellcheck, Python lint, daemon dry-run.

---

## Requirements

- CyberDeck Pi4 base project installed and working
- GeeekPi UPS Plus V5 HAT (EP-0136) seated on the GPIO header
- 18650 batteries installed (two cells, same chemistry — do not mix types)
- UPS firmware updated (see above)
- Internet access for the initial firmware update only — everything else is local

---

## Install

```bash
git clone https://github.com/your-org/cyberdeck-pi4-ups-addon.git
cd cyberdeck-pi4-ups-addon
sudo ./scripts/install-ups.sh
```

The installer will:

1. Enable I2C via `raspi-config nonint`
2. Fix `dtparam=i2c_arm=off` in `/boot/firmware/config.txt` if the PiTFT helper wrote it
3. Install `i2c-tools` and `python3-smbus2` if missing
4. Verify the UPS is visible at `0x17` on I2C bus 1
5. Install `ups_shutdown.sh` to `/opt/cyberdeck-pi4/scripts/`
6. Install `ups_daemon.py` to `/opt/cyberdeck-pi4/ups/`
7. Update `SHUTDOWN_CMD` in `/etc/cyberdeck-pi4/tft.conf`
8. Patch the web UI nginx location for the shutdown endpoint
9. Enable and start `cyberdeck-ups.service`

A reboot is required if I2C was not previously enabled or if `config.txt` was modified.
The installer will tell you.

---

## How It Works

### Shutdown path

Both the TFT shutdown button (GPIO 17, 3-second hold) and the web UI shutdown button call
the same script:

```
/opt/cyberdeck-pi4/scripts/ups_shutdown.sh
```

This script:
1. Writes `20` to UPS register `0x18` (shutdown countdown) via `i2cset`
2. Waits 2 seconds for the I2C write to settle
3. Calls `/sbin/shutdown -h now`

The Pi OS halts cleanly. Approximately 18 seconds later the UPS cuts power to the board.

### Battery telemetry path

`ups_daemon.py` runs as a systemd service and polls the UPS every 30 seconds:

```
UPS I2C registers → ups_daemon.py → /run/cyberdeck-pi4/battery.json
                                  → /stats.json endpoint (nginx)
```

The TFT panel's `battery.py` already reads `/run/cyberdeck-pi4/battery.json` — no changes
to the panel code are needed. The web UI battery widget reads the same data via the
`/ups-status.json` endpoint.

### Register map used

| Register | Function | Notes |
|---|---|---|
| `0x01-0x02` | MCU voltage (mV) | Internal health check |
| `0x03-0x04` | Pogopin voltage (mV) | 5V output to Pi |
| `0x05-0x06` | Battery terminal voltage (mV) | Cell voltage |
| `0x07-0x08` | USB-C charge port voltage (mV) | 0 if unplugged |
| `0x09-0x0A` | MicroUSB charge port voltage (mV) | 0 if unplugged |
| `0x0B-0x0C` | Battery temperature (°C) | Cutoff at 65°C |
| `0x13-0x14` | Battery remaining (%) | Requires calibration cycle |
| `0x17` | Power status | 1 = on, 0 = fault |
| `0x18` | Shutdown countdown (sec) | Write 10–255 to trigger |
| `0x19` | Back-To-AC auto power-up | 1 = enabled |

---

## Configuration

`/etc/cyberdeck-pi4/tft.conf` gains one new key after install:

```ini
# --- UPS addon ---
UPS_I2C_BUS=1
UPS_I2C_ADDR=0x17
UPS_SHUTDOWN_DELAY=20    # seconds UPS waits after Pi halts before cutting power
UPS_POLL_SEC=30          # how often the daemon reads UPS registers
```

---

## Troubleshooting

**UPS not found on I2C bus:**
```bash
sudo i2cdetect -y 1
```
If `0x17` is absent: check HAT seating, check batteries are installed, verify
`dtparam=i2c_arm=on` is the last I2C-related line in `/boot/firmware/config.txt`.

**All registers read zero:**
UPS firmware is frozen. Follow the firmware update procedure at the top of this document.

**`/dev/i2c-1` missing after reboot:**
The PiTFT helper may have re-added `dtparam=i2c_arm=off`. Run the installer again or
check the bottom of `/boot/firmware/config.txt` manually.

**Daemon not starting:**
```bash
sudo systemctl status cyberdeck-ups
sudo journalctl -u cyberdeck-ups -n 50
```

**TFT panel still shows `NO SENSOR`:**
```bash
cat /run/cyberdeck-pi4/battery.json
```
If the file is absent, the daemon hasn't written its first reading yet. Check daemon status
above. If the file exists but the panel doesn't update, restart the panel service:
```bash
sudo systemctl restart cyberdeck-panel
```

---

## Uninstall

```bash
sudo ./scripts/uninstall-ups.sh
```

Stops and removes the daemon, restores `tft.conf` `SHUTDOWN_CMD` to `/sbin/shutdown -h now`,
removes the UPS nginx patch, and removes installed scripts. Does not touch I2C configuration
(harmless to leave enabled).

---

## File Summary

| File | Installed location | Purpose |
|---|---|---|
| `ups_shutdown.sh` | `/opt/cyberdeck-pi4/scripts/` | UPS-aware shutdown — called by TFT button and web UI |
| `ups_daemon.py` | `/opt/cyberdeck-pi4/ups/` | Polling daemon — writes battery.json |
| `install-ups.sh` | repo only | Installer |
| `uninstall-ups.sh` | repo only | Clean removal |
| `ups.conf` | `/etc/cyberdeck-pi4/` | UPS addon config (I2C address, poll interval) |
| `cyberdeck-ups.service` | `/etc/systemd/system/` | systemd unit |
| `ci-ups.yml` | `.github/workflows/` | CI: shellcheck + lint + dry-run |
| `UPS_ADDON.md` | `docs/` | This document (full technical reference) |
