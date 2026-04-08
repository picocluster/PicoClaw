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
    "trustedProxies": ["172.16.0.0/12", "127.0.0.1", "::1"],
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789",
        "https://localhost:18790",
        "https://127.0.0.1:18790",
        "http://picoclaw:18789",
        "http://10.1.10.220:18789"
      ],
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "models": {
    "providers": {
      "local": {
        "baseUrl": "${LOCAL_BASE_URL:-http://picocrush:11434/v1}",
        "apiKey": "none",
        "models": [
          {"id": "llama3.2:3b", "name": "Llama 3.2 3B"},
          {"id": "llama3.1:8b", "name": "Llama 3.1 8B"},
          {"id": "phi3.5:3.8b", "name": "Phi 3.5 Mini"},
          {"id": "qwen2.5:3b", "name": "Qwen 2.5 3B"}
        ]
      }
    }
  }
}
EOF
chmod 600 "$CONFIG"

exec openclaw gateway --port 18789
