#!/usr/bin/env python3
"""
power-api.py — CyberDeck Pi4 Power Management API
Serves on 127.0.0.1:8081 (proxied by nginx)

Endpoints:
  POST /api/lowpower          {"enabled": true/false}  — toggle low power mode (GPIO 23)
  POST /api/ups/backtoac      {"enabled": true/false}  — set UPS Back-To-AC register
  GET  /api/ups/threshold                              — read current threshold from ups.conf
  POST /api/ups/threshold     {"threshold": 15}        — save threshold to ups.conf
"""

import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

CONF_FILE = "/etc/cyberdeck-pi4/ups.conf"
UPS_BUS   = 1
UPS_ADDR  = 0x17

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def read_conf():
    conf = {}
    if not os.path.exists(CONF_FILE):
        return conf
    with open(CONF_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            conf[key.strip()] = val.strip().strip('"').strip("'")
    return conf

def write_conf_key(key, value):
    """Update a single key in ups.conf, preserving all other lines."""
    lines = []
    found = False
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE) as f:
            lines = f.readlines()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(key + "=") or stripped.startswith(key + " ="):
            new_lines.append(f"{key}={value}\n")
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f"{key}={value}\n")
    with open(CONF_FILE, "w") as f:
        f.writelines(new_lines)

def i2c_write(reg, val):
    subprocess.run(
        ["i2cset", "-y", str(UPS_BUS), hex(UPS_ADDR), hex(reg), str(val)],
        check=True, capture_output=True
    )

def i2c_read(reg):
    result = subprocess.run(
        ["i2cget", "-y", str(UPS_BUS), hex(UPS_ADDR), hex(reg)],
        check=True, capture_output=True, text=True
    )
    return int(result.stdout.strip(), 16)

def json_resp(handler, code, data):
    body = json.dumps(data).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", len(body))
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.end_headers()
    handler.wfile.write(body)

# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------
class PowerHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # suppress default access log spam

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/ups/threshold":
            self._get_threshold()
        elif self.path == "/api/ping":
            json_resp(self, 200, {"status": "ok"})
        else:
            json_resp(self, 404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            json_resp(self, 400, {"error": "invalid JSON"})
            return

        if self.path == "/api/lowpower":
            self._post_lowpower(data)
        elif self.path == "/api/ups/backtoac":
            self._post_backtoac(data)
        elif self.path == "/api/ups/threshold":
            self._post_threshold(data)
        elif self.path == "/api/shutdown":
            self._post_shutdown()
        else:
            json_resp(self, 404, {"error": "not found"})

    # -------------------------------------------------------------------------
    # Handlers
    # -------------------------------------------------------------------------
    def _get_threshold(self):
        conf = read_conf()
        threshold = int(conf.get("UPS_SHUTDOWN_THRESHOLD", 15))
        json_resp(self, 200, {"threshold": threshold})

    def _post_threshold(self, data):
        val = data.get("threshold")
        if val is None or not isinstance(val, int) or not (5 <= val <= 50):
            json_resp(self, 400, {"error": "threshold must be integer 5-50"})
            return
        try:
            write_conf_key("UPS_SHUTDOWN_THRESHOLD", val)
            json_resp(self, 200, {"status": "saved", "threshold": val})
        except Exception as e:
            json_resp(self, 500, {"error": str(e)})

    def _post_lowpower(self, data):
        enabled = data.get("enabled", False)
        try:
            # GPIO 23 low power toggle — same as the physical button action
            # The button daemon toggles hostapd/AP; we replicate that here
            # by calling the same script the button daemon uses
            action = "on" if enabled else "off"
            result = subprocess.run(
                ["/opt/cyberdeck-pi4/scripts/lowpower.sh", action],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                json_resp(self, 500, {"error": result.stderr.strip()})
            else:
                json_resp(self, 200, {"status": "ok", "lowpower": enabled})
        except FileNotFoundError:
            # lowpower.sh doesn't exist yet — fall back to direct hostapd toggle
            try:
                svc_action = "stop" if enabled else "start"
                subprocess.run(["systemctl", svc_action, "hostapd"], check=True)
                json_resp(self, 200, {"status": "ok", "lowpower": enabled,
                                      "note": "toggled hostapd directly"})
            except Exception as e:
                json_resp(self, 500, {"error": str(e)})
        except Exception as e:
            json_resp(self, 500, {"error": str(e)})

    def _post_backtoac(self, data):
        enabled = data.get("enabled", False)
        try:
            i2c_write(0x19, 1 if enabled else 0)
            json_resp(self, 200, {"status": "ok", "back_to_ac": enabled})
        except Exception as e:
            json_resp(self, 500, {"error": str(e)})

    def _post_shutdown(self):
        try:
            subprocess.Popen(
                ["sudo", "/opt/cyberdeck-pi4/scripts/ups_shutdown.sh"],
                close_fds=True
            )
            json_resp(self, 200, {"status": "shutdown_initiated"})
        except Exception as e:
            json_resp(self, 500, {"error": str(e)})

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8081), PowerHandler)
    print("CyberDeck power-api listening on 127.0.0.1:8081")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
