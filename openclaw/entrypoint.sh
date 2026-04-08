#!/bin/bash
set -e

CONFIG="/home/openclaw/.openclaw/openclaw.json"

# Always regenerate config from env vars to ensure consistency
cat > "$CONFIG" <<EOF
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "${OPENCLAW_TOKEN:-picocluster-token}"
    },
    "bind": "lan",
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789",
        "http://picoclaw:18789",
        "http://10.1.10.220:18789"
      ]
    }
  },
  "models": {
    "providers": {
      "local": {
        "baseUrl": "${LOCAL_BASE_URL:-http://picocrush:8080/v1}",
        "apiKey": "none",
        "models": [
          {
            "id": "${LOCAL_MODEL:-Llama-3.2-3B-Instruct-Q4_K_M.gguf}",
            "name": "Llama 3.2 3B"
          }
        ]
      }
    }
  }
}
EOF
chmod 600 "$CONFIG"

exec openclaw gateway --port 18789
