#!/bin/bash
set -e

# Write .env from environment variables. Defaults match the Dockerfile ENV
# values; docker-compose overrides these via the `environment:` section.
# LOCAL_MODEL must be an Ollama tag that supports tool calling. llama3.1:8b
# chains tool calls reliably across multi-turn conversations.
cat > /app/backend/.env <<EOF
LLM_PROVIDER=${LLM_PROVIDER:-local}
LOCAL_BASE_URL=${LOCAL_BASE_URL:-http://picocrush:11434/v1}
LOCAL_MODEL=${LOCAL_MODEL:-llama3.1:8b}
EOF

# Start backend using venv
cd /app/backend
/app/venv/bin/python server.py &
BACKEND_PID=$!

sleep 3

# Auto-connect all PicoClaw MCP servers
connect_mcp() {
  local name="$1"
  local script="$2"
  if [ -f "$script" ]; then
    curl -sf -X POST http://127.0.0.1:8000/api/mcp/connect \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${name}\",\"command\":\"python3\",\"args\":[\"${script}\"]}" \
      > /dev/null && echo "MCP connected: ${name}" || echo "MCP failed: ${name}"
  fi
}

connect_mcp "leds" "/opt/mcp/led_server.py"
connect_mcp "system" "/opt/mcp/servers/system_info_server.py"
connect_mcp "picocrush" "/opt/mcp/servers/picocrush_server.py"
connect_mcp "time" "/opt/mcp/servers/time_server.py"
connect_mcp "files" "/opt/mcp/servers/files_server.py"

# Start frontend
cd /app/frontend
npx vite --host 0.0.0.0 --port 5173 &
FRONTEND_PID=$!

wait -n $BACKEND_PID $FRONTEND_PID
kill $BACKEND_PID $FRONTEND_PID 2>/dev/null
