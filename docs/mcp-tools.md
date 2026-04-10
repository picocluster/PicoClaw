# PicoClaw MCP Tools Reference

PicoClaw ships with 5 MCP (Model Context Protocol) servers that auto-connect to ThreadWeaver on startup. The local LLM gets **28 tools** total (4 built-in + 24 from MCP servers).

## Quick Reference

| Server | Tools | Description |
|--------|------:|-------------|
| [leds](#led-server) | 5 | Control the Blinkt! LED strip |
| [system](#system-server) | 6 | picoclaw system stats |
| [picocrush](#picocrush-server) | 4 | Ollama model management |
| [time](#time-server) | 4 | Current time and dates |
| [files](#files-server) | 5 | Sandboxed file operations |

---

## LED Server

Controls the 8-LED Pimoroni Blinkt! strip on picoclaw's GPIO header.

| Tool | Description |
|------|-------------|
| `set_led_color` | Set all LEDs to a color (red, green, blue, amber, cyan, purple, white). Auto-clears after 10s. |
| `set_led_progress` | Show a progress bar (0-100%) with color. Auto-clears after 30s. |
| `led_pulse_success` | Green burst animation. |
| `led_pulse_error` | Red flash animation. |
| `clear_leds` | Return to idle scanner animation. |

**Example chat:**
> User: "Make the LEDs purple"
> LLM: *calls `set_led_color` with `{"color": "purple"}`* → Blinkt! turns purple

### HTTP API

Also available as raw HTTP on port 7777 (reachable from your LAN):

```bash
curl -X POST http://picoclaw:7777/set_status -H 'Content-Type: application/json' -d '{"color":"purple"}'
curl -X POST http://picoclaw:7777/set_progress -H 'Content-Type: application/json' -d '{"percent":50,"color":"green"}'
curl -X POST http://picoclaw:7777/pulse_success
curl -X POST http://picoclaw:7777/pulse_error
curl -X POST http://picoclaw:7777/clear
```

Colors: `red`, `green`, `blue`, `amber`, `cyan`, `purple`, `white`, `off`

Or use the `pc-led` wrapper from any SSH session on picoclaw:

```bash
ssh picocluster@picoclaw
pc-led color purple 10
pc-led flash red
pc-led progress 75 green
pc-led success
pc-led clear
```

### Portal Controls

The [PicoClaw portal](http://picoclaw) has an LED Control section with color buttons, pulse effects, and a progress slider.

### OpenClaw Auto-LED

A log-monitoring bridge automatically triggers LED effects on OpenClaw agent events:
- Agent thinking → purple
- Tool use → cyan
- Success → green burst
- Error → red flash

---

## System Server

Reports picoclaw (RPi5) system statistics.

| Tool | Description |
|------|-------------|
| `get_cpu_info` | CPU load, cores, and utilization |
| `get_memory_info` | RAM and swap usage |
| `get_disk_info` | Filesystem usage |
| `get_temperature` | CPU temperature (Celsius + Fahrenheit) |
| `get_uptime` | System uptime |
| `get_network_info` | Network interfaces and IP addresses |

**Example chat:**
> User: "How hot is picoclaw running?"
> LLM: *calls `get_temperature`* → "CPU temperature: 52.3C (126.1F)"

---

## Picocrush Server

Manages the Ollama inference server on picocrush (Jetson Orin Nano).

| Tool | Description |
|------|-------------|
| `list_ollama_models` | List all installed LLM models with sizes |
| `get_active_models` | Show models currently loaded in GPU memory |
| `get_gpu_memory` | NVIDIA GPU memory and utilization stats |
| `pull_ollama_model` | Download a new model from the Ollama library |

**Example chat:**
> User: "What models are loaded right now and how much VRAM are they using?"
> LLM: *calls `get_active_models`* → "llama3.1:8b: 4.9GB VRAM, expires in 5 min"

---

## Time Server

Gives the LLM awareness of current date and time. Important because training data has a cutoff date.

| Tool | Description |
|------|-------------|
| `get_current_time` | Current date and time (local or UTC) |
| `get_day_of_week` | Current day of the week |
| `time_until` | Calculate time remaining until a target date |
| `format_duration` | Format seconds as human-readable (e.g. "2d 3h 45m") |

**Example chat:**
> User: "How long until Christmas?"
> LLM: *calls `time_until` with `{"target": "2026-12-25"}`* → "260 days, 4 hours, 12 minutes until 2026-12-25"

---

## Files Server

Sandboxed file operations — the LLM can read/write/delete files only within `/tmp/picoclcaw-sandbox` (mounted as a Docker volume so it persists across restarts).

| Tool | Description |
|------|-------------|
| `list_files` | List files in the sandbox (or a subdirectory) |
| `read_file` | Read a file's contents |
| `write_file` | Write content to a file (creates parent dirs as needed) |
| `delete_file` | Delete a file |
| `get_sandbox_path` | Get the sandbox directory path |

**Example chat:**
> User: "Write a shopping list with milk, eggs, and bread to shopping.txt"
> LLM: *calls `write_file` with the list* → "Wrote 21 bytes to shopping.txt"

### Security

The sandbox uses Python's `Path.resolve()` + `relative_to()` to reject any path that escapes the sandbox directory. The LLM cannot read `/etc/passwd`, access containers, or touch anything outside `/tmp/picoclcaw-sandbox`.

---

## Adding Your Own MCP Server

All PicoClaw MCP servers use a shared base (`mcp/mcp_base.py`) that handles the stdio protocol. To add a new server:

```python
#!/usr/bin/env python3
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_base import run_server

TOOLS = [
    {
        "name": "my_tool",
        "description": "What this tool does",
        "inputSchema": {
            "type": "object",
            "properties": {
                "param": {"type": "string", "description": "..."},
            },
            "required": ["param"],
        },
    },
]

def handle_call(name, args):
    if name == "my_tool":
        return f"Result for {args['param']}"
    return f"Unknown tool: {name}"

if __name__ == "__main__":
    run_server("my-server", "1.0.0", TOOLS, handle_call)
```

Save it to `mcp/my_server.py`, add a `connect_mcp` line to `threadweaver/start.sh`, and rebuild the ThreadWeaver container.

## Third-Party MCP Servers

ThreadWeaver can connect to any stdio-based MCP server. Popular ones:

- **@modelcontextprotocol/server-filesystem** — file operations (use our sandboxed version instead)
- **@modelcontextprotocol/server-brave-search** — web search (requires API key, defeats privacy)
- **@modelcontextprotocol/server-github** — GitHub API access
- **@modelcontextprotocol/server-sqlite** — SQLite database queries

Connect via the ThreadWeaver API. The API is bound to `127.0.0.1` only, so run this from picoclaw itself (via SSH or by opening ThreadWeaver in the browser and using its settings UI):

```bash
ssh picocluster@picoclaw
curl -X POST http://127.0.0.1:8000/api/mcp/connect \
  -H "Content-Type: application/json" \
  -d '{"name":"filesystem","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]}'
```

Or, if you've set up the SSH tunnel, you can hit the API through the Caddy HTTPS wrapper from your own machine: `https://localhost:5174/api/mcp/connect`.

**Note:** Third-party servers need to be reachable from inside the ThreadWeaver container. You may need to mount them as volumes or install them in the Docker image.

## Model Compatibility

Tool use quality varies by model:

| Model | Tool Use | Multi-turn | Notes |
|-------|----------|------------|-------|
| llama3.1:8b | ⭐⭐⭐⭐ | ✅ reliable | **PicoClaw default.** Chains 3+ tool calls cleanly |
| deepseek-r1:7b | ⭐⭐⭐⭐ | ✅ reliable | Good reasoning about when to use tools |
| phi3.5:3.8b | ⭐⭐⭐ | ⚠️ variable | Decent on single/first-turn tool use |
| qwen2.5:3b | ⭐⭐⭐ | ⚠️ variable | Better at code than tools |
| llama3.2:3b | ⭐⭐⭐ | ❌ degrades | First 1-2 calls work, then hallucinates tool calls as text |
| starcoder2:3b | ❌ no tools | — | Code completion model; ThreadWeaver falls back to chat-only |
| gemma3:4b | ❌ no tools | — | Chat model; ThreadWeaver falls back to chat-only |
| llava:7b | ❌ no tools | — | Vision model; use for image understanding |
| moondream:1.8b | ❌ no tools | — | Tiny vision model; use for fast image description |

**The multi-turn degradation pattern** for `llama3.2:3b`: by the third or fourth request in a conversation, the model starts printing tool calls as text in the content body instead of emitting real structured tool calls. ThreadWeaver can't distinguish the hallucinated call from a real one, and the model often fabricates plausible results immediately after — so replies read correctly but nothing actually happened. Check the LEDs or the sandbox if you're unsure.

**Recommendation:** Use `llama3.1:8b` (the default) for any tool-heavy conversation. Switch to `llama3.2:3b` only for quick one-shot questions where you don't need tools. For vision tasks, use `llava:7b` or `moondream:1.8b` and let ThreadWeaver's auto-fallback handle the tool schemas.
