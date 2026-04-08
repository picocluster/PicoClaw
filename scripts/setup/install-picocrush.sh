#!/bin/bash
# install-picocrush.sh — Install llama-server + models on Orin Nano
# Run on a golden image (after build-orin-image.sh + configure-pair.sh)
#
# Installs: llama.cpp (CUDA build), GGUF models, model switcher
# Configures: systemd service, firewall, MAXN power mode
#
# Usage: sudo bash install-picocrush.sh [picoclaw-ip]
set -euo pipefail

CLAW_IP="${1:-10.1.10.220}"
LLAMA_PORT="8080"
NVME_MOUNT="/mnt/nvme"
LLAMA_DIR="$NVME_MOUNT/llama.cpp"
MODEL_DIR="$NVME_MOUNT/models"
LLAMA_BIN="$LLAMA_DIR/build/bin/llama-server"
DEFAULT_MODEL="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
USER="picocluster"
CTX_SIZE=32768

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
log "=== PicoCrush Install (picocrush / Orin Nano) ==="
log "  NVMe: ${NVME_MOUNT}"
log "  Default model: ${DEFAULT_MODEL}"
log "  Allow inference from: ${CLAW_IP}"
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
log "--- Step 1/8: Verify CUDA ---"
if ! nvidia-smi &>/dev/null; then
  log "ERROR: nvidia-smi failed. CUDA not available."
  exit 1
fi
log "CUDA OK: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"

# ============================================================
# 2. Mount NVMe
# ============================================================
log "--- Step 2/8: NVMe ---"
mkdir -p "$NVME_MOUNT"
chown "${USER}:${USER}" "$NVME_MOUNT"

if ! grep -q "$NVME_MOUNT" /etc/fstab; then
  echo "/dev/nvme0n1p1  ${NVME_MOUNT}  ext4  defaults,nofail  0  2" >> /etc/fstab
fi
mount "$NVME_MOUNT" 2>/dev/null || true

if mountpoint -q "$NVME_MOUNT"; then
  log "NVMe mounted at $NVME_MOUNT ($(df -h $NVME_MOUNT | awk 'NR==2 {print $4}') free)"
else
  log "WARNING: NVMe not mounted — models will go on root filesystem"
fi

# ============================================================
# 3. Build llama.cpp
# ============================================================
log "--- Step 3/8: llama.cpp ---"
apt install -y cmake build-essential libcurl4-openssl-dev 2>&1 | tail -3

if [[ -f "$LLAMA_BIN" ]]; then
  log "llama-server binary exists, skipping build"
else
  if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    sudo -u "$USER" git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
  fi
  log "Building llama.cpp with CUDA (this takes ~10 minutes)..."
  cd "$LLAMA_DIR"
  sudo -u "$USER" mkdir -p build
  cd build
  sudo -u "$USER" cmake .. -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87
  sudo -u "$USER" make -j$(nproc)
  log "Build complete"
fi

if [[ ! -f "$LLAMA_BIN" ]]; then
  log "ERROR: llama-server not found at $LLAMA_BIN"
  exit 1
fi
log "llama-server: $LLAMA_BIN"

# ============================================================
# 4. Download models
# ============================================================
log "--- Step 4/8: Models ---"
mkdir -p "$MODEL_DIR"
chown "${USER}:${USER}" "$MODEL_DIR"

declare -A MODELS
MODELS["Llama-3.2-3B-Instruct-Q4_K_M.gguf"]="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
MODELS["Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"]="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
MODELS["Phi-3.5-mini-instruct-Q4_K_M.gguf"]="https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
MODELS["Qwen2.5-3B-Instruct-Q4_K_M.gguf"]="https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf"

for model in "${!MODELS[@]}"; do
  if [[ -f "$MODEL_DIR/$model" ]]; then
    log "  $model: exists ($(du -h "$MODEL_DIR/$model" | cut -f1))"
  else
    log "  $model: downloading..."
    sudo -u "$USER" wget -q --show-progress -O "$MODEL_DIR/$model" "${MODELS[$model]}" || {
      log "  WARNING: Failed to download $model"
      rm -f "$MODEL_DIR/$model"
    }
  fi
done

log "Models in $MODEL_DIR:"
ls -lh "$MODEL_DIR"/*.gguf 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'

# ============================================================
# 5. Model switcher
# ============================================================
log "--- Step 5/8: Model switcher ---"
cat > /usr/local/bin/model-switch <<'SWITCHER'
#!/bin/bash
# model-switch — Switch the active model on llama-server
# Usage: model-switch [model-name.gguf]
#        model-switch --list
set -euo pipefail

MODEL_DIR="/mnt/nvme/models"
SERVICE="llama-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

if [[ "${1:-}" == "--list" || -z "${1:-}" ]]; then
  echo "Available models:"
  current=$(grep -oP '(?<=--model )\S+' "$SERVICE_FILE" 2>/dev/null | xargs basename)
  for f in "$MODEL_DIR"/*.gguf; do
    name=$(basename "$f")
    size=$(du -h "$f" | cut -f1)
    if [[ "$name" == "$current" ]]; then
      echo "  * $name ($size) [ACTIVE]"
    else
      echo "    $name ($size)"
    fi
  done
  exit 0
fi

MODEL_NAME="$1"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

# Allow partial matches
if [[ ! -f "$MODEL_PATH" ]]; then
  MATCH=$(find "$MODEL_DIR" -name "*${MODEL_NAME}*" -name "*.gguf" | head -1)
  if [[ -n "$MATCH" ]]; then
    MODEL_PATH="$MATCH"
    MODEL_NAME=$(basename "$MATCH")
  else
    echo "ERROR: Model '$MODEL_NAME' not found in $MODEL_DIR"
    echo "Run: model-switch --list"
    exit 1
  fi
fi

echo "Switching to: $MODEL_NAME"
echo "Stopping llama-server..."
systemctl stop "$SERVICE"

# Update the service file
sed -i "s|--model [^ ]*|--model ${MODEL_PATH}|" "$SERVICE_FILE"
systemctl daemon-reload

echo "Starting llama-server with $MODEL_NAME..."
systemctl start "$SERVICE"

# Wait for health
for i in $(seq 1 30); do
  if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q '"ok"'; then
    echo "llama-server ready with $MODEL_NAME"
    exit 0
  fi
  sleep 2
done

echo "WARNING: llama-server did not become healthy within 60 seconds"
systemctl status "$SERVICE" --no-pager | head -10
SWITCHER
chmod +x /usr/local/bin/model-switch
log "Model switcher installed at /usr/local/bin/model-switch"

# ============================================================
# 6. Power mode
# ============================================================
log "--- Step 6/8: Power mode ---"
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
# 7. llama-server service + firewall
# ============================================================
log "--- Step 7/8: llama-server service ---"
cat > /etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=llama.cpp inference server
After=network.target jetson-maxperf.service
Wants=jetson-maxperf.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${LLAMA_DIR}
ExecStart=${LLAMA_BIN} \
  --model ${MODEL_DIR}/${DEFAULT_MODEL} \
  --port ${LLAMA_PORT} \
  --host 0.0.0.0 \
  --n-gpu-layers 99 \
  --ctx-size ${CTX_SIZE} \
  --parallel 1
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Firewall — restrict llama-server to picoclaw only
ufw allow from "${CLAW_IP}" to any port "${LLAMA_PORT}" comment "llama-server from picoclaw" 2>/dev/null || true
log "Firewall: port ${LLAMA_PORT} open for ${CLAW_IP} only"

# ============================================================
# 8. Start and test
# ============================================================
log "--- Step 8/8: Start and test ---"
systemctl daemon-reload
systemctl enable llama-server
systemctl restart llama-server

log "Waiting for llama-server..."
for i in $(seq 1 30); do
  if curl -s --max-time 2 http://127.0.0.1:${LLAMA_PORT}/health | grep -q '"ok"'; then
    log "llama-server: HEALTHY"
    break
  fi
  sleep 2
done

# Quick inference test
log "Inference test..."
RESULT=$(curl -s --max-time 30 http://127.0.0.1:${LLAMA_PORT}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}' 2>/dev/null)
if echo "$RESULT" | grep -q '"content"'; then
  log "Inference test: PASSED"
else
  log "Inference test: FAILED — $RESULT"
fi

# GPU memory
GPU_MEM=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null)
log "GPU memory: $GPU_MEM"

log ""
log "============================================"
log "  PicoCrush Install Complete"
log "============================================"
log ""
log "  llama-server: http://picocrush:${LLAMA_PORT}"
log "  Active model: ${DEFAULT_MODEL}"
log "  Switch model: sudo model-switch --list"
log "  Models: ${MODEL_DIR}/"
log ""
log "  GPU: ${GPU_MEM}"
log "============================================"
