#!/bin/bash
# install-picoclaw.sh — Install full PicoClaw stack on RPi5 via Docker
# Run on a golden image (after build-rpi5-image.sh + configure-pair.sh)
#
# Installs: OpenClaw (Docker), ThreadWeaver (Docker), Blinkt! LEDs (native)
#
# Usage: sudo bash install-picoclaw.sh [picocrush-ip]
set -euo pipefail

CRUSH_IP="${1:-10.1.10.221}"
DEFAULT_MODEL="${2:-Llama-3.2-3B-Instruct-Q4_K_M.gguf}"
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
ufw allow 18789/tcp comment "OpenClaw WebChat" 2>/dev/null || true
ufw deny 18791/tcp comment "OpenClaw control" 2>/dev/null || true
ufw deny 18792/tcp comment "OpenClaw CDP relay" 2>/dev/null || true
ufw allow 5173/tcp comment "ThreadWeaver UI" 2>/dev/null || true
ufw allow 8000/tcp comment "ThreadWeaver API" 2>/dev/null || true
log "Firewall configured"

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
log "  OpenClaw:      $(curl -sf --max-time 5 http://127.0.0.1:18789/__openclaw__/canvas/ >/dev/null 2>&1 && echo 'OK' || echo 'STARTING')"
log "  Blinkt! LEDs:  $(systemctl is-active picoclaw-leds 2>/dev/null || echo 'n/a')"
log "  llama-server:  $(curl -sf --max-time 5 http://${CRUSH_IP}:8080/health >/dev/null 2>&1 && echo 'OK' || echo 'NOT REACHABLE')"

log ""
log "============================================"
log "  PicoClaw Install Complete"
log "============================================"
log ""
log "  ThreadWeaver:  http://picoclaw:5173"
log "  OpenClaw:      http://picoclaw:18789  (token: ${OPENCLAW_TOKEN})"
log ""
log "  Manage:  cd $INSTALL_DIR && docker compose [up -d|down|logs|ps]"
log "  Update:  cd $INSTALL_DIR && git pull && docker compose build --pull && docker compose up -d"
log "============================================"
