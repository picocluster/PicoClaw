#!/bin/bash
# install-picoclaw.sh — Install full PicoClaw stack on RPi5 via Docker
# Run on a golden image (after build-rpi5-image.sh + configure-pair.sh)
#
# Installs: OpenClaw (Docker), ThreadWeaver (Docker), Blinkt! LEDs (native)
#
# Usage: sudo bash install-picoclaw.sh [picocrush-ip]
set -euo pipefail

CRUSH_IP="${1:-10.1.10.221}"
# Ollama tag (not a llamafile .gguf filename). Must be a model that supports
# tool calling since ThreadWeaver sends MCP tool schemas on every request.
# llama3.1:8b is the default because it reliably chains tool calls across
# multi-turn conversations; the smaller llama3.2:3b works for 1-2 calls but
# degrades on longer tool-heavy threads. Other tool-capable models:
# phi3.5:3.8b, qwen2.5:3b, deepseek-r1:7b. Gemma3 and vision models do NOT
# support tool calling (ThreadWeaver auto-falls back to chat-only for those).
DEFAULT_MODEL="${2:-llama3.1:8b}"
OPENCLAW_TOKEN="${3:-picocluster-token}"
INSTALL_DIR="/opt/picoclcaw"
LED_DIR="$INSTALL_DIR/leds"
USER="picocluster"

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== PicoClaw Install (picoclaw / RPi5) ==="
log "  picocrush: ${CRUSH_IP}"
log "  Model: ${DEFAULT_MODEL}"
log ""

# ============================================================
# 0. Resize filesystem if needed
# ============================================================
DISK="/dev/mmcblk0"
PARTDEV="${DISK}p2"
DISK_SIZE=$(lsblk -b -n -o SIZE "$DISK" 2>/dev/null | head -1)
PART_SIZE=$(lsblk -b -n -o SIZE "$PARTDEV" 2>/dev/null | head -1)

if [[ -n "$DISK_SIZE" && -n "$PART_SIZE" ]]; then
  # Resize if partition is less than 90% of disk
  THRESHOLD=$(( DISK_SIZE * 90 / 100 ))
  if (( PART_SIZE < THRESHOLD )); then
    log "--- Step 0: Resizing filesystem ---"
    START_SECTOR=$(fdisk -l "$DISK" | grep "^${PARTDEV}" | awk '{print $2}')
    if [[ -n "$START_SECTOR" ]]; then
      fdisk "$DISK" <<EOF > /dev/null 2>&1
d
2
n
p
2
$START_SECTOR

w
EOF
      partprobe "$DISK"
      resize2fs "$PARTDEV"
      log "Filesystem resized: $(df -h / | awk 'NR==2 {print $2}')"
    fi
  else
    log "Filesystem already sized correctly: $(df -h / | awk 'NR==2 {print $2}')"
  fi
fi

# ============================================================
# Cleanup: Remove legacy leftover files
# ============================================================
log "--- Cleanup: Removing legacy files ---"
LEGACY_FILES=(
  "/home/${USER}/genKeys.sh"
  "/home/${USER}/resizeAllNodes.sh"
  "/home/${USER}/resize_rpi.sh"
  "/home/${USER}/resize_raspbian.sh"
  "/home/${USER}/restartAllNodes.sh"
  "/home/${USER}/stopAllNodes.sh"
  "/home/${USER}/testAllNodes.sh"
  "/home/${USER}/build-rpi5-image.sh"
  "/home/${USER}/install-picoclaw.sh"
)
for f in "${LEGACY_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    log "  Removed $f"
  fi
done
if [[ -d "/home/${USER}/.ansible" ]]; then
  rm -rf "/home/${USER}/.ansible"
  log "  Removed .ansible/"
fi

# ============================================================
# 1. Docker
# ============================================================
log "--- Step 1/5: Docker ---"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$USER"
  systemctl enable docker
  log "Docker installed"
else
  log "Docker $(docker --version | awk '{print $3}') already installed"
fi

# ============================================================
# 2. Clone PicoClaw repo (for Dockerfiles + compose)
# ============================================================
log "--- Step 2/5: PicoClaw repo ---"
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/picocluster/PicoClaw.git "$INSTALL_DIR"
  log "PicoClaw repo cloned"
else
  cd "$INSTALL_DIR" && git pull --ff-only 2>&1 | tail -3
  log "PicoClaw repo updated"
fi

# ============================================================
# 3. Build and start Docker containers
# ============================================================
log "--- Step 3/5: Docker build + start ---"
cd "$INSTALL_DIR"

# Write .env for docker-compose
cat > "$INSTALL_DIR/.env" <<EOF
CRUSH_IP=${CRUSH_IP}
DEFAULT_MODEL=${DEFAULT_MODEL}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
EOF

log "Building containers (this takes a few minutes on first run)..."
docker compose build 2>&1 | tail -10
docker compose up -d 2>&1
log "Containers started"

# ============================================================
# 4. Blinkt! LEDs (native — needs GPIO access)
# ============================================================
log "--- Step 4/5: Blinkt! LEDs ---"
apt install -y python3-gpiod 2>/dev/null || pip3 install --break-system-packages gpiod 2>/dev/null || true

mkdir -p "$LED_DIR"
cp "$INSTALL_DIR/leds/apa102.py" "$LED_DIR/" 2>/dev/null || true
cp "$INSTALL_DIR/leds/picoclaw_status.py" "$LED_DIR/" 2>/dev/null || true

if [[ -f "$INSTALL_DIR/leds/picoclaw-leds.service" ]]; then
  cp "$INSTALL_DIR/leds/picoclaw-leds.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable picoclaw-leds
  systemctl start picoclaw-leds
  log "Blinkt! LED daemon started"
else
  log "Blinkt! LED service file not found — skipping"
fi

# ============================================================
# 5. Firewall
# ============================================================
log "--- Step 5/5: Firewall ---"
ufw allow 80/tcp comment "PicoClaw Portal" 2>/dev/null || true
ufw allow 7777/tcp comment "LED API" 2>/dev/null || true
ufw allow 8888/tcp comment "Shutdown API" 2>/dev/null || true

# Install host-based shutdown API (not in Docker — needs system shutdown access)
if [[ -f "$INSTALL_DIR/portal/shutdown-api.service" ]]; then
  cp "$INSTALL_DIR/portal/shutdown-api.service" /etc/systemd/system/
  echo "picocluster ALL=(ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot" > /etc/sudoers.d/picoclcaw-shutdown
  chmod 440 /etc/sudoers.d/picoclcaw-shutdown
  systemctl daemon-reload
  systemctl enable shutdown-api
  systemctl start shutdown-api
  log "Shutdown API installed"
fi
ufw allow 18790/tcp comment "OpenClaw Dashboard (HTTPS via Caddy)" 2>/dev/null || true
ufw allow 5174/tcp comment "ThreadWeaver HTTPS (via Caddy)" 2>/dev/null || true
ufw deny 18791/tcp comment "OpenClaw control" 2>/dev/null || true
ufw deny 18792/tcp comment "OpenClaw CDP relay" 2>/dev/null || true
# All raw HTTP ports below are bound to 127.0.0.1 only via docker-compose;
# LAN access goes through Caddy HTTPS (5174, 18790) via SSH tunnel.
# Explicitly delete stale ALLOW rules and replace with DENY so the posture is
# self-documenting and idempotent across reinstalls.
for port in 5173 8000 18789; do
  ufw delete allow "${port}/tcp" 2>/dev/null || true
done
ufw deny 18789/tcp comment "OpenClaw raw HTTP (localhost-only, tunnel via 18790)" 2>/dev/null || true
ufw deny 5173/tcp  comment "ThreadWeaver UI (localhost-only, tunnel via 5174)" 2>/dev/null || true
ufw deny 8000/tcp  comment "ThreadWeaver API (localhost-only)" 2>/dev/null || true
log "Firewall configured"

# ============================================================
# Install user management scripts
# ============================================================
log "--- Installing user management scripts ---"
USER_BIN="/home/${USER}/bin"
if [[ -d "$INSTALL_DIR/scripts/user-bin/picoclaw" ]]; then
  mkdir -p "$USER_BIN"
  cp "$INSTALL_DIR/scripts/user-bin/picoclaw/"* "$USER_BIN/"
  chmod +x "$USER_BIN/"*
  chown -R "${USER}:${USER}" "$USER_BIN"
  log "  Installed: $(ls "$USER_BIN" | tr '\n' ' ')"

  # Ensure ~/bin is in PATH for the picocluster user (Raspbian default .profile handles this,
  # but only if ~/bin exists at login time — we just created it, so force-source it)
  if ! grep -q "HOME/bin" "/home/${USER}/.bashrc" 2>/dev/null; then
    cat >> "/home/${USER}/.bashrc" <<'BASHRC'

# PicoClaw user scripts
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi
BASHRC
  fi
else
  log "  WARNING: user-bin/picoclaw not found in repo — skipping"
fi

# ============================================================
# Verify
# ============================================================
log ""
log "Waiting for services to start..."
sleep 10

log "=== Service Status ==="
docker compose ps 2>/dev/null
echo ""
log "  ThreadWeaver:  $(curl -sf --max-time 5 http://127.0.0.1:8000/api/settings >/dev/null 2>&1 && echo 'OK' || echo 'STARTING')"
log "  OpenClaw:      $(curl -sf --max-time 5 http://127.0.0.1:18789/__openclaw__/health >/dev/null 2>&1 && echo 'OK' || echo 'STARTING')"
log "  Blinkt! LEDs:  $(systemctl is-active picoclaw-leds 2>/dev/null || echo 'n/a')"
log "  Ollama:        $(curl -sf --max-time 5 http://${CRUSH_IP}:11434/api/tags >/dev/null 2>&1 && echo 'OK' || echo 'NOT REACHABLE')"

log ""
log "============================================"
log "  PicoClaw Install Complete"
log "============================================"
log ""
log "  ThreadWeaver:  https://localhost:5174   (via SSH tunnel)"
log "  OpenClaw:      https://localhost:18790  (via SSH tunnel, token: ${OPENCLAW_TOKEN})"
log ""
log "  SSH tunnel command (run on your computer):"
log "    ssh -L 5174:localhost:5174 -L 18790:localhost:18790 picocluster@picoclaw"
log ""
log "  Manage:  cd $INSTALL_DIR && docker compose [up -d|down|logs|ps]"
log "  Update:  cd $INSTALL_DIR && git pull && docker compose build --pull && docker compose up -d"
log "============================================"
