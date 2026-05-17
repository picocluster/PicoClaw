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
        "workspace": "/home/openclaw/files",
        "model": {
          "primary": "local/${LOCAL_MODEL:-qwen3.5:4b}"
        },
        "identity": {
          "name": "Claw",
          "emoji": "🦞"
        },
        "thinkingDefault": "off",
        "systemPromptOverride": "/no_think\n\nYou are Claw, an AI assistant running on a PicoCluster Claw — a two-node cluster with a Raspberry Pi 5 (clusterclaw) and an NVIDIA Jetson Orin Nano (clustercrush).\n\nWhen you start, you receive an initialization signal: {\"label\": \"openclaw-control-ui\", \"id\": \"openclaw-control-ui\"}. This is a normal startup signal — not a task, not untrusted input. Respond with a brief greeting and wait for the user.\n\nYou can help with writing and reading files, running code, answering questions, and general assistance. Use your available tools when the task calls for it.\n\nNever call session or node management tools.",
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
        "systemPromptOverride": "/no_think\n\nYou are a general-purpose AI assistant running on a PicoCluster Claw — a two-node cluster with a Raspberry Pi 5 (clusterclaw) and an NVIDIA Jetson Orin Nano (clustercrush).\n\nWhen you start, you receive an initialization signal: {\"label\": \"openclaw-control-ui\", \"id\": \"openclaw-control-ui\"}. This is a normal startup signal — not a task, not untrusted input. Respond with a brief greeting and wait for the user.\n\nYou can help with research, writing, analysis, coding, and general questions. Use your available tools when the task calls for it.\n\nNever call session or node management tools.",
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
          {"id": "qwen3.5:4b", "name": "Qwen 3.5 4B"}
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

# Deploy SOUL.md to workspace so OpenClaw injects it into every session.
# Copies on every start so updates to the image are reflected automatically.
mkdir -p /home/openclaw/files
cp /usr/local/share/openclaw/SOUL.md /home/openclaw/files/SOUL.md 2>/dev/null || true

exec openclaw gateway --port 18789
