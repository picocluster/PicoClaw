#!/usr/bin/env python3
"""
PicoClaw LED MCP Server

Exposes the Blinkt! LED strip as MCP tools that any MCP-compatible
client (ThreadWeaver, OpenClaw, Claude Code, etc.) can discover and use.

Tools:
  - set_led_color: Set all LEDs to a solid color with optional pulse
  - set_led_progress: Show a progress bar (0-100%)
  - led_pulse_success: Green burst animation
  - led_pulse_error: Red flash animation
  - clear_leds: Return to idle scanner animation

Runs as a stdio MCP server. Connect via:
  ThreadWeaver: /api/mcp/connect {"name": "leds", "command": "python3", "args": ["/opt/picoclcaw/leds/mcp_server.py"]}
"""

import sys
import json
import urllib.request

import os
LED_API = os.environ.get("LED_API_URL", "http://172.17.0.1:7777")

# ─── MCP Protocol ───────────────────────────────────────────

TOOLS = [
    {
        "name": "set_led_color",
        "description": "Set the PicoClaw Blinkt! LED strip to a solid color. The LEDs will pulse gently in the chosen color. Use to show status, mood, or get the user's attention. Available colors: red, green, blue, amber, cyan, purple, white.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "color": {
                    "type": "string",
                    "description": "Color name: red, green, blue, amber, cyan, purple, white",
                    "enum": ["red", "green", "blue", "amber", "cyan", "purple", "white"],
                },
                "duration": {
                    "type": "integer",
                    "description": "Seconds to show before returning to scanner. 0 = stay until cleared. Default: 10",
                    "default": 10,
                },
            },
            "required": ["color"],
        },
    },
    {
        "name": "set_led_progress",
        "description": "Show a progress bar on the LED strip. Fills LEDs from left to right proportional to the percentage. Use for multi-step tasks to show the user how far along you are.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "percent": {
                    "type": "integer",
                    "description": "Progress percentage (0-100)",
                    "minimum": 0,
                    "maximum": 100,
                },
                "color": {
                    "type": "string",
                    "description": "Bar color (default: green)",
                    "enum": ["red", "green", "blue", "amber", "cyan", "purple", "white"],
                    "default": "green",
                },
            },
            "required": ["percent"],
        },
    },
    {
        "name": "led_pulse_success",
        "description": "Flash the LEDs with a celebratory green burst. Use when a task completes successfully or to acknowledge the user.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "led_pulse_error",
        "description": "Flash the LEDs red to indicate an error or problem. Use when something goes wrong.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "clear_leds",
        "description": "Return the LEDs to their idle scanner animation. Call this when done using the LEDs.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]


def led_call(endpoint, data=None):
    """Call the LED HTTP API."""
    try:
        body = json.dumps(data or {}).encode()
        req = urllib.request.Request(
            f"{LED_API}/{endpoint}",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        resp = urllib.request.urlopen(req, timeout=3)
        return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e)}


def handle_tool_call(name, arguments):
    """Execute a tool and return the result."""
    if name == "set_led_color":
        result = led_call("set_status", {
            "color": arguments.get("color", "blue"),
            "duration": arguments.get("duration", 10),
        })
        return f"LEDs set to {arguments.get('color', 'blue')}"

    elif name == "set_led_progress":
        result = led_call("set_progress", {
            "percent": arguments.get("percent", 0),
            "color": arguments.get("color", "green"),
        })
        return f"Progress bar at {arguments.get('percent', 0)}%"

    elif name == "led_pulse_success":
        led_call("pulse_success")
        return "Success animation played"

    elif name == "led_pulse_error":
        led_call("pulse_error")
        return "Error animation played"

    elif name == "clear_leds":
        led_call("clear")
        return "LEDs returned to scanner"

    return f"Unknown tool: {name}"


# ─── MCP stdio transport ────────────────────────────────────

def send_response(response):
    """Send a JSON-RPC response to stdout."""
    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()


def main():
    """MCP server main loop — reads JSON-RPC from stdin, responds on stdout."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = request.get("method", "")
        req_id = request.get("id")

        if method == "initialize":
            send_response({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {
                        "tools": {"listChanged": False},
                    },
                    "serverInfo": {
                        "name": "picoclcaw-leds",
                        "version": "1.0.0",
                    },
                },
            })

        elif method == "notifications/initialized":
            pass  # No response needed

        elif method == "tools/list":
            send_response({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "tools": TOOLS,
                },
            })

        elif method == "tools/call":
            params = request.get("params", {})
            tool_name = params.get("name", "")
            arguments = params.get("arguments", {})

            result_text = handle_tool_call(tool_name, arguments)

            send_response({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {"type": "text", "text": result_text},
                    ],
                    "isError": False,
                },
            })

        elif req_id is not None:
            send_response({
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32601,
                    "message": f"Method not found: {method}",
                },
            })


if __name__ == "__main__":
    main()
