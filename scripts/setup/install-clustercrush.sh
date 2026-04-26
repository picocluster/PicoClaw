#!/bin/bash
# install-clustercrush.sh — Install Ollama + models on Orin Nano
# Run on a golden image (after build-orin-image.sh + configure-pair.sh)
#
# Installs: Ollama (CUDA), pulls default model set, warms default model into GPU
# Configures: systemd service, firewall, MAXN power mode
#
# Usage: sudo bash install-clustercrush.sh [clusterclaw-ip] [default-model]
set -euo pipefail

CLAW_IP="${1:-10.1.10.220}"
DEFAULT_MODEL="${2:-llama3.1:8b}"
OLLAMA_PORT="11434"
USER="picocluster"
INSTALL_DIR="/opt/clusterclaw"

# Models to pull — DEFAULT_MODEL is pulled first so it's ready fastest.
# Models must support tool calling for ThreadWeaver MCP.
# Gemma3 and vision models do NOT support tool calling (TW falls back to chat-only).
MODELS=(
  "$DEFAULT_MODEL"
  "llama3.2:3b"
  "phi3.5:3.8b"
  "qwen2.5:3b"
  "deepseek-r1:7b"
  "gemma3:4b"
  "starcoder2:3b"
  "llava:7b"
  "moondream:1.8b"
)
# Deduplicate in case DEFAULT_MODEL is already in the list above
readarray -t MODELS < <(printf '%s\n' "${MODELS[@]}" | awk '!seen[$0]++')

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== PicoCrush Install (clustercrush / Orin Nano) ==="
log "  Allow inference from: ${CLAW_IP}"
log "  Default model: ${DEFAULT_MODEL}"
log "  All models: ${MODELS[*]}"
log ""

# ============================================================
# Set hostname + /etc/hosts — clean up legacy entries
# ============================================================
log "--- Hostname + /etc/hosts ---"

hostnamectl set-hostname clustercrush
sed -i "s/127\.0\.1\.1.*/127.0.1.1\tclustercrush/" /etc/hosts

# Remove ALL legacy PicoCluster managed blocks (old format, new format)
sed -i '/# BEGIN PICOCLUSTER/,/# END PICOCLUSTER/d' /etc/hosts

# Remove stale pcN entries (pc0–pc9, pc10–pc99) from old multi-node images
sed -i '/\bpc[0-9]\{1,2\}\b/d' /etc/hosts

# Remove stale clusterclaw/clustercrush bare lines (we'll rewrite them cleanly)
sed -i '/\bclusterclaw\b/d' /etc/hosts
sed -i '/\bclustercrush\b/d' /etc/hosts

# Write clean cluster host block with short aliases
cat >> /etc/hosts <<HOSTS

# BEGIN PICOCLUSTER CLAW
10.1.10.220  clusterclaw clusterclaw.local claw claw.local
10.1.10.221  clustercrush clustercrush.local crush crush.local
# END PICOCLUSTER CLAW
HOSTS
log "Hostname: clustercrush (alias: crush)"

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
# Cleanup: Remove legacy leftover files
# ============================================================
log "--- Cleanup: Removing legacy files ---"
LEGACY_FILES=(
  "/home/${USER}/genKeys.sh"
  "/home/${USER}/resizeAllNodes.sh"
  "/home/${USER}/resize_ubuntu.sh"
  "/home/${USER}/restartAllNodes.sh"
  "/home/${USER}/stopAllNodes.sh"
  "/home/${USER}/testAllNodes.sh"
  "/home/${USER}/build-orin-image.sh"
  "/home/${USER}/install-clustercrush.sh"
)
for f in "${LEGACY_FILES[@]}"; do
  [[ -f "$f" ]] && rm -f "$f" && log "  Removed $f"
done
[[ -d "/home/${USER}/.ansible" ]] && rm -rf "/home/${USER}/.ansible" && log "  Removed .ansible/"

# ============================================================
# Clone PicoCluster Claw repo
# ============================================================
log "--- PicoCluster Claw repo ---"
if ! command -v git &>/dev/null; then
  apt-get install -y git 2>/dev/null | tail -1
fi
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/picocluster/PicoCluster-Claw.git "$INSTALL_DIR"
  log "Repo cloned to $INSTALL_DIR"
else
  cd "$INSTALL_DIR" && git pull --ff-only 2>&1 | tail -3
  log "Repo updated"
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
apt-get install -y zstd 2>/dev/null | tail -1

if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.ai/install.sh | sh
  log "Ollama installed"
else
  log "Ollama already installed: $(ollama --version 2>/dev/null)"
fi

# Ollama systemd override:
#   OLLAMA_HOST        — listen on all interfaces so clusterclaw can reach it
#   OLLAMA_KEEP_ALIVE  — keep loaded models in GPU memory for 1h after last request;
#                        the warmup service pins the default model at boot so first-
#                        request lag is eliminated, and this window covers a typical
#                        session with pauses between messages
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=1h"
EOF

# Model storage on NVMe if available, otherwise default location
if mountpoint -q /mnt/nvme 2>/dev/null; then
  mkdir -p /mnt/nvme/ollama/models
  chown -R ollama:ollama /mnt/nvme/ollama 2>/dev/null || chown -R "$USER:$USER" /mnt/nvme/ollama
  echo 'Environment="OLLAMA_MODELS=/mnt/nvme/ollama/models"' \
    >> /etc/systemd/system/ollama.service.d/override.conf
  log "Model storage: /mnt/nvme/ollama/models"
else
  log "NVMe not mounted — models will use default location (~/.ollama/models)"
fi

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# Wait for Ollama to be ready
log "Waiting for Ollama to be ready..."
for i in $(seq 1 30); do
  if curl -sf --max-time 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    log "Ollama ready"
    break
  fi
  sleep 2
done

# ============================================================
# 3. Pull models (default model first)
# ============================================================
log "--- Step 3/6: Pull models ---"
for model in "${MODELS[@]}"; do
  log "  Pulling $model..."
  ollama pull "$model" 2>&1 | tail -1
done
log "Available models:"
ollama list 2>&1 | head -20

# ============================================================
# 4. Startup warm-up service
# ============================================================
log "--- Step 4/6: Ollama warm-up service ---"

# A lightweight script that fires after Ollama starts and loads the default
# model into GPU memory. With keep_alive=1h, the model stays resident for
# the first hour after boot (and resets to 1h on every real request), so
# users never experience the cold-load delay.
cat > /usr/local/bin/ollama-warmup <<WARMUP
#!/bin/bash
# Wait for Ollama API to be ready, then pre-load the default model.
MODEL="${DEFAULT_MODEL}"
PORT="${OLLAMA_PORT}"
for i in \$(seq 1 30); do
  if curl -sf --max-time 2 "http://127.0.0.1:\${PORT}/api/tags" &>/dev/null; then
    break
  fi
  sleep 2
done
# Empty prompt — Ollama loads the model without generating any tokens.
# keep_alive=1h pins it in GPU memory for one hour (refreshed by each request).
curl -sf -X POST "http://127.0.0.1:\${PORT}/api/generate" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"\${MODEL}\",\"prompt\":\"\",\"stream\":false,\"keep_alive\":\"1h\"}" \
  &>/dev/null && echo "Ollama: \${MODEL} warmed into GPU memory" \
             || echo "Ollama: warm-up request failed (model may load on first request)"
WARMUP
chmod +x /usr/local/bin/ollama-warmup

cat > /etc/systemd/system/ollama-warmup.service <<EOF
[Unit]
Description=Pre-warm Ollama default model into GPU memory
After=ollama.service
Wants=ollama.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ollama-warmup

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ollama-warmup
log "Warm-up service installed: ${DEFAULT_MODEL} will be hot-loaded on every boot"

# Run the warm-up now so we don't wait for a reboot
log "Running warm-up now..."
/usr/local/bin/ollama-warmup

# ============================================================
# 5. Power mode
# ============================================================
log "--- Step 5/6: Power mode ---"
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
# 6. Firewall
# ============================================================
log "--- Step 6/6: Firewall ---"
ufw allow from "${CLAW_IP}" to any port "${OLLAMA_PORT}" \
  comment "Ollama from clusterclaw" 2>/dev/null || true
log "Firewall: port ${OLLAMA_PORT} open for ${CLAW_IP} only"

# ============================================================
# User management scripts
# ============================================================
USER_BIN="/home/${USER}/bin"
if [[ -d "$INSTALL_DIR/scripts/user-bin/clustercrush" ]]; then
  mkdir -p "$USER_BIN"
  cp "$INSTALL_DIR/scripts/user-bin/clustercrush/"* "$USER_BIN/"
  chmod +x "$USER_BIN/"*
  chown -R "${USER}:${USER}" "$USER_BIN"
  if ! grep -q "HOME/bin" "/home/${USER}/.bashrc" 2>/dev/null; then
    cat >> "/home/${USER}/.bashrc" <<'BASHRC'

# PicoCluster Claw user scripts
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi
BASHRC
  fi
  log "User scripts installed: $(ls "$USER_BIN" | tr '\n' ' ')"
fi

# ============================================================
# Test
# ============================================================
log "--- Verify ---"
if curl -sf --max-time 5 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" | grep -q "models"; then
  log "Ollama health: OK"
else
  log "Ollama health: FAIL"
fi

GPU_MEM=$(free -h | awk '/^Mem:/ {printf "%s used / %s total (unified)", $3, $2}')

log ""
log "============================================"
log "  PicoCrush Install Complete"
log "============================================"
log ""
log "  Ollama:    http://clustercrush:${OLLAMA_PORT}"
log "  OAI API:   http://clustercrush:${OLLAMA_PORT}/v1"
log "  Warmed:    ${DEFAULT_MODEL} (hot in GPU on every boot)"
log "  Memory:    ${GPU_MEM}"
log ""
log "  Manage models:"
log "    ollama list              # Show installed models"
log "    ollama pull <model>      # Download a model"
log "    ollama rm <model>        # Remove a model"
log "    ollama run <model>       # Interactive chat"
log "============================================"
