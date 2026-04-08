#!/bin/bash
# install-picocrush.sh — Install Ollama + models on Orin Nano
# Run on a golden image (after build-orin-image.sh + configure-pair.sh)
#
# Installs: Ollama (CUDA), pulls default model set
# Configures: systemd service, firewall, MAXN power mode
#
# Usage: sudo bash install-picocrush.sh [picoclaw-ip]
set -euo pipefail

CLAW_IP="${1:-10.1.10.220}"
OLLAMA_PORT="11434"
USER="picocluster"

# Models to pull (first one is the default)
MODELS=(
  "llama3.2:3b"
  "llama3.1:8b"
  "phi3.5:3.8b"
  "qwen2.5:3b"
)

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
log "=== PicoCrush Install (picocrush / Orin Nano) ==="
log "  Allow inference from: ${CLAW_IP}"
log "  Models: ${MODELS[*]}"
log ""

# ============================================================
# 0. Resize filesystem if needed
# ============================================================
DISK="/dev/mmcblk0"
PARTNUM=1
PARTDEV="${DISK}p${PARTNUM}"
DISK_SIZE=$(lsblk -b -n -o SIZE "$DISK" 2>/dev/null | head -1)
PART_SIZE=$(lsblk -b -n -o SIZE "$PARTDEV" 2>/dev/null | head -1)

if [[ -n "$DISK_SIZE" && -n "$PART_SIZE" ]]; then
  THRESHOLD=$(( DISK_SIZE * 90 / 100 ))
  if (( PART_SIZE < THRESHOLD )); then
    log "--- Step 0: Resizing filesystem ---"
    if command -v sgdisk &>/dev/null; then
      START_SECTOR=$(sgdisk -i "$PARTNUM" "$DISK" | grep 'First sector:' | awk '{print $3}')
      sgdisk -e "$DISK"
      sgdisk -d "$PARTNUM" -n "${PARTNUM}:${START_SECTOR}:0" -c "${PARTNUM}:APP" -t "${PARTNUM}:8300" "$DISK"
      partprobe "$DISK"
      resize2fs "$PARTDEV"
      log "Filesystem resized: $(df -h / | awk 'NR==2 {print $2}')"
    else
      log "WARNING: sgdisk not found — run resize_ubuntu.sh manually"
    fi
  else
    log "Filesystem already sized correctly: $(df -h / | awk 'NR==2 {print $2}')"
  fi
fi

# ============================================================
# 1. Verify CUDA
# ============================================================
log "--- Step 1/6: Verify CUDA ---"
if ! nvidia-smi &>/dev/null; then
  log "ERROR: nvidia-smi failed. CUDA not available."
  exit 1
fi
log "CUDA OK: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"

# ============================================================
# 2. Install Ollama
# ============================================================
log "--- Step 2/6: Install Ollama ---"
# Ollama installer requires zstd for extraction
apt install -y zstd 2>/dev/null | tail -1

if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.ai/install.sh | sh
  log "Ollama installed"
else
  log "Ollama already installed: $(ollama --version 2>/dev/null)"
fi

# Configure Ollama to listen on all interfaces
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_MODELS=/mnt/nvme/ollama/models"
EOF

# Create model storage on NVMe if available
if mountpoint -q /mnt/nvme 2>/dev/null; then
  mkdir -p /mnt/nvme/ollama/models
  chown -R ollama:ollama /mnt/nvme/ollama 2>/dev/null || chown -R "$USER:$USER" /mnt/nvme/ollama
  log "Model storage: /mnt/nvme/ollama/models"
else
  log "NVMe not mounted — models will use default location"
  sed -i '/OLLAMA_MODELS/d' /etc/systemd/system/ollama.service.d/override.conf
fi

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# Wait for Ollama to be ready
log "Waiting for Ollama..."
for i in $(seq 1 30); do
  if curl -sf --max-time 2 http://127.0.0.1:${OLLAMA_PORT}/api/tags &>/dev/null; then
    log "Ollama is ready"
    break
  fi
  sleep 2
done

# ============================================================
# 3. Pull models
# ============================================================
log "--- Step 3/6: Pull models ---"
for model in "${MODELS[@]}"; do
  log "  Pulling $model..."
  ollama pull "$model" 2>&1 | tail -1
done

log "Available models:"
ollama list 2>&1 | head -20

# ============================================================
# 4. Power mode
# ============================================================
log "--- Step 4/6: Power mode ---"
nvpmodel -m 2 2>/dev/null || true
jetson_clocks 2>/dev/null || true

if [[ ! -f /etc/systemd/system/jetson-maxperf.service ]]; then
  cat > /etc/systemd/system/jetson-maxperf.service <<EOF
[Unit]
Description=Set Jetson to MAXN power mode
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nvpmodel -m 2
ExecStartPost=/usr/bin/jetson_clocks
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable jetson-maxperf
fi
log "MAXN power mode set and persisted"

# ============================================================
# 5. Firewall
# ============================================================
log "--- Step 5/6: Firewall ---"
ufw allow from "${CLAW_IP}" to any port "${OLLAMA_PORT}" comment "Ollama from picoclaw" 2>/dev/null || true
log "Firewall: port ${OLLAMA_PORT} open for ${CLAW_IP} only"

# ============================================================
# 6. Test
# ============================================================
log "--- Step 6/6: Test ---"

# Health check
if curl -sf --max-time 5 http://127.0.0.1:${OLLAMA_PORT}/api/tags | grep -q "models"; then
  log "Ollama health: OK"
else
  log "Ollama health: FAIL"
fi

# Inference test
log "Inference test..."
RESULT=$(curl -sf --max-time 60 http://127.0.0.1:${OLLAMA_PORT}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODELS[0]}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_tokens\":5}" 2>/dev/null)
if echo "$RESULT" | grep -q '"content"'; then
  log "Inference test: PASSED"
else
  log "Inference test: FAILED"
fi

# GPU info
GPU_MEM=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null)
log "GPU memory: $GPU_MEM"

log ""
log "============================================"
log "  PicoCrush Install Complete"
log "============================================"
log ""
log "  Ollama: http://picocrush:${OLLAMA_PORT}"
log "  OpenAI API: http://picocrush:${OLLAMA_PORT}/v1"
log ""
log "  Manage models:"
log "    ollama list              # Show installed models"
log "    ollama pull <model>      # Download a model"
log "    ollama rm <model>        # Remove a model"
log "    ollama run <model>       # Interactive chat"
log ""
log "  GPU: ${GPU_MEM}"
log "============================================"
