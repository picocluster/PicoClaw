"""
LED Control API — HTTP server on port 7777 (localhost only).

Provides tool-call endpoints for OpenClaw and other services
to control the Blinkt! LEDs for status reporting.

Endpoints:
  POST /set_status     {"color": "blue", "message": "thinking"}
  POST /set_progress   {"percent": 50, "color": "green"}
  POST /pulse_success  {}
  POST /pulse_error    {"message": "connection failed"}
  POST /clear          {}  (return to idle scanner)

Colors: red, green, blue, amber, cyan, purple, white, off
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import threading
import time

# Shared state — the status daemon reads this
_state = {
    "mode": "idle",       # idle, status, progress, pulse_success, pulse_error
    "color": None,        # (r, g, b) or None
    "message": "",
    "percent": 0,
    "timestamp": 0,       # when the state was set
    "duration": 0,        # how long to show before returning to idle (0 = until cleared)
}
_lock = threading.Lock()

COLOR_MAP = {
    "red":    (255, 0, 0),
    "green":  (0, 255, 0),
    "blue":   (0, 60, 255),
    "amber":  (255, 140, 0),
    "cyan":   (0, 200, 255),
    "purple": (120, 0, 255),
    "white":  (255, 255, 255),
    "off":    (0, 0, 0),
}


def get_state():
    """Get current LED state (called by status daemon)."""
    with _lock:
        # Auto-expire timed states
        if _state["duration"] > 0:
            elapsed = time.time() - _state["timestamp"]
            if elapsed >= _state["duration"]:
                _state["mode"] = "idle"
        return dict(_state)


def set_state(**kwargs):
    """Update LED state."""
    with _lock:
        _state.update(kwargs)
        _state["timestamp"] = time.time()


class LEDHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        content_len = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(content_len)) if content_len else {}

        if self.path == "/set_status":
            color_name = body.get("color", "blue")
            color = COLOR_MAP.get(color_name, COLOR_MAP["blue"])
            duration = body.get("duration", 0)
            set_state(mode="status", color=color, message=body.get("message", ""), duration=duration)
            self._respond(200, {"status": "ok", "mode": "status", "color": color_name})

        elif self.path == "/set_progress":
            percent = max(0, min(100, body.get("percent", 0)))
            color_name = body.get("color", "green")
            color = COLOR_MAP.get(color_name, COLOR_MAP["green"])
            set_state(mode="progress", color=color, percent=percent, message=body.get("message", ""), duration=0)
            self._respond(200, {"status": "ok", "mode": "progress", "percent": percent})

        elif self.path == "/pulse_success":
            set_state(mode="pulse_success", color=COLOR_MAP["green"], message=body.get("message", ""), duration=2)
            self._respond(200, {"status": "ok", "mode": "pulse_success"})

        elif self.path == "/pulse_error":
            set_state(mode="pulse_error", color=COLOR_MAP["red"], message=body.get("message", ""), duration=3)
            self._respond(200, {"status": "ok", "mode": "pulse_error"})

        elif self.path == "/clear":
            set_state(mode="idle", color=None, message="", percent=0, duration=0)
            self._respond(200, {"status": "ok", "mode": "idle"})

        else:
            self._respond(404, {"error": "unknown endpoint"})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _respond(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        pass  # Suppress access logs


def start_api_server(port=7777):
    """Start the LED API server in a background thread."""
    server = HTTPServer(("127.0.0.1", port), LEDHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server
