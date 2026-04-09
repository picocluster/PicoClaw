#!/usr/bin/env python3
"""PicoClaw shutdown/restart API.

Runs as a systemd service on the host (not a container) so it has
access to ssh, sudo, and system shutdown commands.

Listens on 0.0.0.0:8888. Token-protected to prevent accidental triggers.
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess
import json
import os
import urllib.request

TOKEN = os.environ.get("SHUTDOWN_TOKEN", "picocluster-shutdown")
CRUSH_IP = os.environ.get("CRUSH_IP", "10.1.10.221")
CRUSH_USER = os.environ.get("CRUSH_USER", "picocluster")
LED_API = os.environ.get("LED_API_URL", "http://127.0.0.1:7777")


def led_call(endpoint, data=None):
    """Trigger an LED effect. Fails silently."""
    try:
        req = urllib.request.Request(
            f"{LED_API}/{endpoint}",
            data=json.dumps(data or {}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        action = self.path.lstrip("/")
        if action not in ("shutdown", "restart"):
            self._respond(404, {"error": "unknown endpoint"})
            return

        content_len = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(content_len)) if content_len else {}

        if body.get("token") != TOKEN:
            self._respond(403, {"error": "invalid token"})
            return

        target = body.get("target", "all")
        if target not in ("all", "picoclaw", "picocrush"):
            self._respond(400, {"error": f"invalid target: {target}"})
            return

        self._respond(200, {"status": f"{action} initiated", "target": target})

        # Visual feedback before the cluster goes dark
        # Pulsing color — amber for restart, red for shutdown
        color = "amber" if action == "restart" else "red"
        led_call("set_status", {"color": color, "duration": 90})

        # Execute after response is sent
        cmd = "reboot" if action == "restart" else "shutdown -h now"

        if target in ("all", "picocrush"):
            subprocess.Popen(
                ["sudo", "-u", "picocluster",
                 "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
                 f"{CRUSH_USER}@{CRUSH_IP}", f"sudo {cmd}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

        if target in ("all", "picoclaw"):
            # Delay 3 seconds so response goes out and picocrush command starts
            delay = "+1" if action == "shutdown" else ""
            if action == "shutdown":
                subprocess.Popen(
                    ["sudo", "shutdown", "-h", "+1", "PicoClaw shutdown via portal"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            else:
                subprocess.Popen(
                    ["sudo", "shutdown", "-r", "+1", "PicoClaw restart via portal"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8888), Handler)
    print("Shutdown API listening on :8888")
    server.serve_forever()
