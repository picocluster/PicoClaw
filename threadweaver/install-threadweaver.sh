#!/bin/bash
# install-threadweaver.sh — Install ThreadWeaver chat UI on picoclaw (RPi5)
# Native install (no Docker) — runs backend + frontend as systemd services
set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

CRUSH_IP="${1:-10.1.10.221}"
LLAMA_PORT="${2:-8080}"
MODEL="${3:-Llama-3.2-3B-Instruct-Q4_K_M.gguf}"
INSTALL_DIR="/opt/picoclcaw/threadweaver"
TW_USER="picocluster"

echo "=== Installing ThreadWeaver ==="
echo "  LLM endpoint: http://${CRUSH_IP}:${LLAMA_PORT}/v1"
echo "  Model: ${MODEL}"

# Clone or update repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "Updating existing install..."
  cd "$INSTALL_DIR"
  git pull --ff-only
else
  echo "Cloning ThreadWeaver..."
  mkdir -p "$INSTALL_DIR"
  git clone --depth 1 https://github.com/nosqltips/ThreadWeaver.git "$INSTALL_DIR"
fi

# Install backend
echo "Setting up backend..."
cd "$INSTALL_DIR/backend"
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --no-cache-dir -r requirements.txt 2>&1 | tail -3

# Write .env for backend
cat > "$INSTALL_DIR/backend/.env" <<EOF
LLM_PROVIDER=local
LOCAL_BASE_URL=http://${CRUSH_IP}:${LLAMA_PORT}/v1
LOCAL_MODEL=${MODEL}
EOF

# Install frontend
echo "Setting up frontend..."
cd "$INSTALL_DIR/frontend"
npm install 2>&1 | tail -5

# Allow all hosts in Vite (needed for LAN access by hostname)
cat > "$INSTALL_DIR/frontend/vite.config.js" <<'VITE'
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

export default defineConfig({
	plugins: [sveltekit()],
	server: {
		allowedHosts: true
	}
});
VITE

# Patch API_BASE to use relative paths (allows LAN access via Vite proxy)
sed -i "s|const API_BASE = 'http://localhost:8000/api'|const API_BASE = '/api'|g" \
  "$INSTALL_DIR/frontend/src/lib/api.ts" \
  "$INSTALL_DIR/frontend/src/routes/+page.svelte" 2>/dev/null

# Set ownership
chown -R "$TW_USER:$TW_USER" "$INSTALL_DIR"

# Deploy systemd service
cat > /etc/systemd/system/threadweaver.service <<EOF
[Unit]
Description=ThreadWeaver Chat UI
After=network.target

[Service]
Type=forking
User=${TW_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/bash -c '\
  cd ${INSTALL_DIR}/backend && ${INSTALL_DIR}/venv/bin/python server.py & \
  cd ${INSTALL_DIR}/frontend && npx vite --host 0.0.0.0 --port 5173 &'
ExecStop=/bin/bash -c 'pkill -f "server.py" ; pkill -f "vite.*5173"'
Restart=always
RestartSec=5
Environment=HOME=/home/${TW_USER}
EnvironmentFile=${INSTALL_DIR}/backend/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable threadweaver.service
systemctl start threadweaver.service

# Open firewall
ufw allow 5173/tcp comment "ThreadWeaver UI" 2>/dev/null || true
ufw allow 8000/tcp comment "ThreadWeaver API" 2>/dev/null || true

sleep 5
echo ""
echo "=== ThreadWeaver installed ==="
echo "  Chat UI: http://picoclaw:5173"
echo "  API:     http://picoclaw:8000"
echo ""
systemctl status threadweaver.service --no-pager | head -10
