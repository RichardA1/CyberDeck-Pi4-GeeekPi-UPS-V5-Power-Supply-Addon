# Makefile — CyberDeck Pi4 UPS V5 Addon
# Run on the Pi: make install / make uninstall / make status

.PHONY: install uninstall status logs lint check-i2c

install:
	sudo ./scripts/install-ups.sh

uninstall:
	sudo ./scripts/uninstall-ups.sh

status:
	@echo "=== Service ==="
	@systemctl status cyberdeck-ups --no-pager || true
	@echo ""
	@echo "=== battery.json ==="
	@cat /run/cyberdeck-pi4/battery.json 2>/dev/null || echo "(not found)"
	@echo ""
	@echo "=== ups-status.json ==="
	@cat /run/cyberdeck-pi4/ups-status.json 2>/dev/null || echo "(not found)"

logs:
	journalctl -u cyberdeck-ups -f

check-i2c:
	@echo "=== I2C bus scan ==="
	sudo i2cdetect -y 1
	@echo ""
	@echo "=== UPS register dump ==="
	python3 - <<'EOF'
import smbus2
bus = smbus2.SMBus(1)
def r16(r): return bus.read_byte_data(0x17,r)|(bus.read_byte_data(0x17,r+1)<<8)
def r8(r):  return bus.read_byte_data(0x17,r)
print(f"MCU Voltage:       {r16(0x01)} mV")
print(f"Pogopin Voltage:   {r16(0x03)} mV")
print(f"Battery Terminal:  {r16(0x05)} mV")
print(f"USB-C Voltage:     {r16(0x07)} mV")
print(f"MicroUSB Voltage:  {r16(0x09)} mV")
print(f"Battery Temp:      {r16(0x0B)} C")
print(f"Battery Remaining: {r16(0x13)} %")
print(f"Power Status:      {r8(0x17)}")
print(f"Shutdown CD:       {r8(0x18)} sec")
print(f"Back-To-AC:        {r8(0x19)}")
EOF

lint:
	shellcheck scripts/install-ups.sh scripts/uninstall-ups.sh scripts/ups_shutdown.sh
	flake8 scripts/ups_daemon.py --max-line-length=100
