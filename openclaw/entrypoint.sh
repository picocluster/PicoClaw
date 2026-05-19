#!/bin/bash
set -e

CONFIG="/home/openclaw/.openclaw/openclaw.json"

# ── System prompts ────────────────────────────────────────────────────────────
# Kept short so qwen3.5:4b (a 4B model) reliably follows them.
# Key rules:
#   1. Startup signal (first message) = one brief greeting, then stop.
#   2. Every subsequent user task = actually DO it with tools, don't describe.
# Session management tools are blocked by the deny list at the infra level.
#
# $'...' syntax gives real newlines; jq -Rs . encodes them as \n in JSON.

MAIN_PROMPT=$'/no_think\n\nYou are Claw, an AI assistant on a PicoCluster Claw (Raspberry Pi 5 + NVIDIA Jetson Orin Nano).\n\nThe very first message in each session is a system startup signal. Respond with one short greeting, then stop and wait for the real request.\n\nFor every task the user gives you: USE YOUR TOOLS to do the work. If asked to write a file, write it. If asked to read a file, read it. If asked to search the web, search. Do not describe what you could do — just do it.\n\nAfter a tool returns a result, report the result to the user in plain language. Never respond with a greeting after a tool call.\n\nNever call: sessions_list, session_status, sessions_history, sessions_spawn, sessions_yield, subagents, nodes, device_pair, canvas.'

CHAT_PROMPT=$'/no_think\n\nYou are a helpful AI assistant on a PicoCluster Claw.\n\nThe very first message in each session is a system startup signal. Respond with one short greeting, then stop and wait for the real request.\n\nFor every task the user gives you: USE YOUR TOOLS to do the work. Do not describe capabilities — actually use them. After a tool returns a result, report the result in plain language.\n\nNever call: sessions_list, session_status, sessions_history, sessions_spawn, sessions_yield, subagents, nodes, device_pair, canvas.'

# Encode prompts as proper JSON strings (with \n escapes, surrounding quotes).
# --argjson in jq requires valid JSON, so this handles newline encoding correctly.
MAIN_PROMPT_JSON=$(printf '%s' "$MAIN_PROMPT" | jq -Rs .)
CHAT_PROMPT_JSON=$(printf '%s' "$CHAT_PROMPT" | jq -Rs .)

# ── Config write/patch ────────────────────────────────────────────────────────
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
        "systemPromptOverride": ${MAIN_PROMPT_JSON},
        "tools": {
          "deny": [
            "sessions_list", "session_status", "sessions_history",
            "sessions_spawn", "sessions_yield", "subagents",
            "nodes", "device_pair", "canvas",
            "cron", "browser", "message", "process",
            "gateway", "tts", "memory_search", "memory_get", "sessions_send"
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
        "systemPromptOverride": ${CHAT_PROMPT_JSON},
        "tools": {
          "deny": [
            "sessions_list", "session_status", "sessions_history",
            "sessions_spawn", "sessions_yield", "subagents",
            "nodes", "device_pair", "canvas",
            "cron", "browser", "message", "process",
            "gateway", "tts", "memory_search", "memory_get", "sessions_send"
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
        "request": {
          "allowPrivateNetwork": true
        },
        "models": [
          {"id": "granite4.1:8b",      "name": "Granite 4.1 8B"},
          {"id": "nemotron-3-nano:4b", "name": "Nemotron 3 Nano 4B"},
          {"id": "llama3.1:8b",        "name": "Llama 3.1 8B"},
          {"id": "llama3.2:3b",        "name": "Llama 3.2 3B"},
          {"id": "qwen3.5:4b",         "name": "Qwen 3.5 4B"},
          {"id": "deepseek-r1:7b",     "name": "DeepSeek R1 7B"},
          {"id": "qwen3.5:14b",        "name": "Qwen 3.5 14B (large tier — 16 GB+ desktop only)"},
          {"id": "deepseek-r1:14b",    "name": "DeepSeek R1 14B (large tier — 16 GB+ desktop only)"},
          {"id": "phi-4:14b",          "name": "Phi-4 14B (large tier — 16 GB+ desktop only)"}
        ]
      }
    }
  }
}
EOF
chmod 600 "$CONFIG"
else
  # Config exists — patch managed fields on every start so image updates
  # (token, system prompts) are always reflected without deleting the volume.
  TOKEN="${OPENCLAW_TOKEN:-picocluster-token}"
  BASE_URL="${LOCAL_BASE_URL:-http://clustercrush:11434/v1}"
  if command -v jq &>/dev/null; then
    tmp=$(mktemp)
    jq --arg t "$TOKEN" \
       --arg base_url "$BASE_URL" \
       --argjson mp "$MAIN_PROMPT_JSON" \
       --argjson cp "$CHAT_PROMPT_JSON" \
       '.gateway.auth.token = $t |
        .agents.list = (.agents.list | map(
          if .id == "main" then
            .systemPromptOverride = $mp |
            .tools.deny = [
              "sessions_list","session_status","sessions_history",
              "sessions_spawn","sessions_yield","subagents",
              "nodes","device_pair","canvas",
              "cron","browser","message","process",
              "gateway","tts","memory_search","memory_get","sessions_send"
            ]
          elif .id == "chat" then
            .systemPromptOverride = $cp |
            .tools.deny = [
              "sessions_list","session_status","sessions_history",
              "sessions_spawn","sessions_yield","subagents",
              "nodes","device_pair","canvas",
              "cron","browser","message","process",
              "gateway","tts","memory_search","memory_get","sessions_send"
            ]
          else . end
        )) |
        .models.providers.local.baseUrl = $base_url |
        .models.providers.local.request.allowPrivateNetwork = true |
        .models.providers.local.models = [
          {"id": "granite4.1:8b",      "name": "Granite 4.1 8B"},
          {"id": "nemotron-3-nano:4b", "name": "Nemotron 3 Nano 4B"},
          {"id": "llama3.1:8b",        "name": "Llama 3.1 8B"},
          {"id": "llama3.2:3b",        "name": "Llama 3.2 3B"},
          {"id": "qwen3.5:4b",         "name": "Qwen 3.5 4B"},
          {"id": "deepseek-r1:7b",     "name": "DeepSeek R1 7B"},
          {"id": "qwen3.5:14b",        "name": "Qwen 3.5 14B (large tier — 16 GB+ desktop only)"},
          {"id": "deepseek-r1:14b",    "name": "DeepSeek R1 14B (large tier — 16 GB+ desktop only)"},
          {"id": "phi-4:14b",          "name": "Phi-4 14B (large tier — 16 GB+ desktop only)"}
        ]' \
       "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
    chmod 600 "$CONFIG"
  fi
fi

# Deploy workspace context files on every start so image updates are reflected.
#
# Context budget rationale — smaller models (4-8B) have ~8k effective context.
# We aggressively trim injected files and deny heavy tool schemas to keep the
# per-request context under ~8k chars, leaving headroom for conversation history.
#
# AGENTS.md: custom lean version (≈700 chars vs 7.7k default boilerplate)
# SOUL.md:   PicoCluster identity (≈800 chars, kept as-is)
# Others:    placeholder files (TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md)
#            are deleted if empty/default — they burn context for zero value.
mkdir -p /home/openclaw/files
cp /usr/local/share/openclaw/SOUL.md /home/openclaw/files/SOUL.md 2>/dev/null || true
cp /usr/local/share/openclaw/AGENTS.md /home/openclaw/files/AGENTS.md 2>/dev/null || true

# Remove empty placeholder files that OpenClaw creates on first run.
# They contain only template instructions with no actual data, so injecting
# them wastes ~2.5k chars of context. Remove only if they are unmodified stubs
# (i.e. the user hasn't filled them in yet — detected by absence of real data).
for stub in TOOLS.md IDENTITY.md USER.md HEARTBEAT.md; do
  f="/home/openclaw/files/$stub"
  if [ -f "$f" ]; then
    # If the file has no non-comment, non-empty, non-template content, remove it.
    real_lines=$(grep -v '^\s*#\|^\s*_\|^\s*-\s*\*\*\|^\s*$\|^```' "$f" | wc -l)
    if [ "$real_lines" -lt 2 ]; then
      rm -f "$f"
    fi
  fi
done

exec openclaw gateway --port 18789
