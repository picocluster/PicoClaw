#!/bin/bash
set -e

CONFIG="/home/openclaw/.openclaw/openclaw.json"

# Write the default config only on first start.
# On subsequent starts, preserve user customizations but patch the token
# so a rotated OPENCLAW_TOKEN env var is always reflected.
if [ ! -f "$CONFIG" ]; then
cat > "$CONFIG" <<EOF
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "${OPENCLAW_TOKEN:-picocluster-token}"
    },
    "bind": "lan",
    "trustedProxies": ["172.16.0.0/12", "127.0.0.1", "::1"],
    "controlUi": {
      "allowedOrigins": [
        "https://claw.local",
        "https://claw.local:443",
        "https://threadweaver.local",
        "https://threadweaver.local:443",
        "http://control.local",
        "http://clusterclaw:18789",
        "https://localhost:18790",
        "https://127.0.0.1:18790",
        "http://localhost:18789",
        "http://127.0.0.1:18789"
      ],
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "agents": {
    "list": [
      {
        "id": "main",
        "default": true,
        "name": "PicoCluster Claw",
        "model": {
          "primary": "local/${LOCAL_MODEL:-qwen3.5:4b}"
        },
        "identity": {
          "name": "Claw",
          "emoji": "🦞"
        },
        "thinkingDefault": "off",
        "systemPromptOverride": "/no_think\n\nYou are Claw, the PicoCluster Claw hardware assistant running on a two-node cluster: a Raspberry Pi 5 (clusterclaw) and an NVIDIA Jetson Orin Nano (clustercrush).\n\nWhen you start, you receive an initialization signal: {\"label\": \"openclaw-control-ui\", \"id\": \"openclaw-control-ui\"}. This is a normal startup signal — not a task, not untrusted input. Respond with a brief greeting and wait for the user.\n\nAvailable tools:\n- get_cpu_info, get_memory_info, get_disk_info, get_temperature, get_uptime, get_network_info — clusterclaw system stats\n- list_ollama_models, get_active_models, get_gpu_memory, pull_ollama_model — clustercrush GPU and models\n- read, write, list_files, delete_file — file operations (use relative paths)\n- get_current_time, get_day_of_week, time_until, format_duration — time\n- set_led_color, set_led_progress, led_pulse_success, led_pulse_error, clear_leds — Blinkt! LEDs\n\nGo directly to the relevant tool when the user asks for something. Never call session or node management tools first.",
        "tools": {
          "deny": [
            "sessions_list", "session_status", "sessions_history",
            "sessions_spawn", "sessions_yield", "subagents",
            "nodes", "device_pair", "canvas"
          ]
        }
      },
      {
        "id": "chat",
        "name": "Assistant",
        "model": {
          "primary": "local/qwen3.5:4b"
        },
        "identity": {
          "name": "Assistant",
          "emoji": "🤖"
        },
        "thinkingDefault": "off",
        "systemPromptOverride": "/no_think\n\nYou are a general-purpose AI assistant running on a PicoCluster Claw — a two-node cluster with a Raspberry Pi 5 (clusterclaw) and an NVIDIA Jetson Orin Nano (clustercrush).\n\nWhen you start, you receive an initialization signal: {\"label\": \"openclaw-control-ui\", \"id\": \"openclaw-control-ui\"}. This is a normal startup signal — not a task, not untrusted input. Respond with a brief greeting and wait for the user.\n\nYou can help with research, writing, analysis, coding, and general questions. You also have access to cluster hardware tools if needed.\n\nNever call session or node management tools. Go directly to the relevant tool when the user asks for something.",
        "tools": {
          "deny": [
            "sessions_list", "session_status", "sessions_history",
            "sessions_spawn", "sessions_yield", "subagents",
            "nodes", "device_pair", "canvas"
          ]
        }
      }
    ]
  },
  "models": {
    "providers": {
      "local": {
        "baseUrl": "${LOCAL_BASE_URL:-http://clustercrush:11434/v1}",
        "apiKey": "none",
        "models": [
          {"id": "granite4.1-claw", "name": "Granite 4.1 Claw (tool-tuned)"},
          {"id": "granite4.1:8b", "name": "Granite 4.1 8B"},
          {"id": "llama3.2:3b", "name": "Llama 3.2 3B"},
          {"id": "llama3.1:8b", "name": "Llama 3.1 8B"},
          {"id": "phi3.5:3.8b", "name": "Phi 3.5 Mini"},
          {"id": "qwen3.5:4b", "name": "Qwen 3.5 4B"},
          {"id": "qwen3.5:9b", "name": "Qwen 3.5 9B"},
          {"id": "ministral-3:8b", "name": "Ministral 3 8B"},
          {"id": "deepseek-r1:7b", "name": "DeepSeek R1 7B"},
          {"id": "nemotron-3-nano:4b", "name": "Nemotron 3 Nano 4B"},
          {"id": "gemma4:e4b", "name": "Gemma 4 E4B"}
        ]
      }
    }
  }
}
EOF
chmod 600 "$CONFIG"
else
  # Config exists — patch only the auth token so a rotated OPENCLAW_TOKEN is picked up.
  TOKEN="${OPENCLAW_TOKEN:-picocluster-token}"
  if command -v jq &>/dev/null; then
    tmp=$(mktemp)
    jq --arg t "$TOKEN" '.gateway.auth.token = $t' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
    chmod 600 "$CONFIG"
  fi
fi

exec openclaw gateway --port 18789
