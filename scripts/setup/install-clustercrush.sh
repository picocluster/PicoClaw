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
DEFAULT_MODEL="${2:-qwen3.5:4b}"
# Single model deployment — qwen3.5:4b is the default for both ThreadWeaver and OpenClaw
OLLAMA_PORT="11434"
USER="picocluster"
INSTALL_DIR="/opt/clusterclaw"

MODELS=("$DEFAULT_MODEL")

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
10.1.10.220  clusterclaw clusterclaw.local claw claw.local threadweaver.local control.local
10.1.10.221  clustercrush clustercrush.local crush crush.local
# END PICOCLUSTER CLAW
HOSTS
log "Hostname: clustercrush (alias: crush)"

# Disable IPv6 — consistent with clusterclaw; avoids SLAAC churn and reduces attack surface
ETH_IF=$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|en)[0-9]/{print $2; exit}')
ETH_IF=${ETH_IF:-eth0}
cat > /etc/sysctl.d/60-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.${ETH_IF}.disable_ipv6=1
EOF
sysctl -p /etc/sysctl.d/60-disable-ipv6.conf 2>/dev/null || true

# ============================================================
# Avahi mDNS — clustercrush.local
# ============================================================
log "--- Avahi mDNS ---"

if ! command -v avahi-daemon &>/dev/null; then
  apt-get install -y avahi-daemon avahi-utils libnss-mdns
  log "Avahi installed"
else
  log "Avahi already installed"
fi

# Restrict to physical LAN interface — prevents Docker bridge interfaces
# from confusing mDNS announcements and causing macOS to miss them.
if ! grep -q "^allow-interfaces" /etc/avahi/avahi-daemon.conf 2>/dev/null; then
  sed -i "s/^\[server\]/[server]\nallow-interfaces=${ETH_IF}/" /etc/avahi/avahi-daemon.conf
fi
# Lock hostname so Avahi never renames on probe conflict
sed -i "s/#host-name=foo/host-name=clustercrush/" /etc/avahi/avahi-daemon.conf
sed -i 's/^use-ipv6=yes/use-ipv6=no/' /etc/avahi/avahi-daemon.conf
# Don't publish AAAA records over IPv4 — suppresses IPv6 conflict triggers
sed -i 's/#publish-aaaa-on-ipv4=yes/publish-aaaa-on-ipv4=no/' /etc/avahi/avahi-daemon.conf

> /etc/avahi/hosts

systemctl enable avahi-daemon
systemctl restart avahi-daemon
log "mDNS: clustercrush.local advertised on ${ETH_IF}"

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
#   OLLAMA_HOST           — listen on all interfaces so clusterclaw can reach it
#   OLLAMA_KEEP_ALIVE     — how long to keep a model in VRAM after the last request.
#                           30m is a good balance: long enough to cover pauses in a
#                           conversation, short enough that models don't stay resident
#                           for hours and starve the next model load. The warmup
#                           service below loads the default model at boot with an
#                           explicit keep_alive=1h so first-request lag is zero.
#                           Do NOT set this to 0 — that unloads after every single
#                           inference call, forcing a ~90s reload on each message.
#   OLLAMA_KV_CACHE_TYPE  — q8_0 quantized KV cache reduces VRAM usage on 8GB Orin Nano
#                           without meaningful quality loss; helps fit 4B models in
#                           unified memory alongside system processes
#   NOTE: OLLAMA_FLASH_ATTENTION is intentionally excluded — it causes silent GPU hangs
#         on Jetson Orin Nano (tested: inference never completes with it enabled)
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
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
log "--- Step 6/7: Firewall ---"
ufw allow from "${CLAW_IP}" to any port "${OLLAMA_PORT}" \
  comment "Ollama from clusterclaw" 2>/dev/null || true
log "Firewall: port ${OLLAMA_PORT} open for ${CLAW_IP} only"

# ============================================================
# 7. Headless-server hardening (dedicated Ollama node)
# ============================================================
log "--- Step 7/7: Headless service cleanup ---"

# Disable services not needed on a dedicated GPU inference node.
# These are safe to remove on a headless, wired-ethernet-only machine.
DISABLE_SERVICES=(
  fail2ban            # SSH brute-force protection (overkill for LAN-only node)
  ModemManager        # Cellular modem management — no modem present
  rpcbind             # NFS/RPC — not needed
  seatd               # Seat manager for desktop sessions
  haveged             # Extra entropy daemon — kernel provides enough
  nvargus-daemon      # Jetson camera/argus daemon — no camera attached
  nvweston            # Wayland compositor — headless, no display
  nvfb                # Framebuffer — headless
  nvfb-early          # Framebuffer early init — headless
  nvfb-udev           # Framebuffer udev — headless
  nvgetty             # Nvidia getty — headless
  unattended-upgrades # Auto-updates can interrupt model loads at bad times
  wpa_supplicant      # WiFi — ethernet-only node
)
for svc in "${DISABLE_SERVICES[@]}"; do
  if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 | grep -q "$svc"; then
    systemctl disable --now "$svc" 2>/dev/null || true
  fi
done

# Disable socket activators that could re-wake stopped services
systemctl disable --now docker.socket rpcbind.socket 2>/dev/null || true

# Ensure Docker is not running on crush — it should run only on clusterclaw.
# If Docker/containerd is running (e.g. someone ran compose here by mistake), stop it.
if systemctl is-active --quiet docker 2>/dev/null; then
  log "  Stopping Docker (should not run on clustercrush)"
  systemctl disable --now docker containerd 2>/dev/null || true
fi

# Purge development packages and profiling tools not needed for inference.
# These can consume several GB of disk on a freshly flashed Jetson image.
DEV_PACKAGES=(
  nsight-compute-2024.3.1
  libcudnn9-static-cuda-12
  libcublas-dev-12-6
  libcufft-dev-12-6
  libnvinfer-dev
  libcusparse-dev-12-6
  libnpp-dev-12-6
  libnpp-12-6
  qemu-efi-aarch64
)
INSTALLED_DEV=()
for pkg in "${DEV_PACKAGES[@]}"; do
  dpkg -l "$pkg" &>/dev/null 2>&1 && INSTALLED_DEV+=("$pkg")
done
if (( ${#INSTALLED_DEV[@]} > 0 )); then
  log "  Purging dev/profiling packages: ${INSTALLED_DEV[*]}"
  apt-get purge -y "${INSTALLED_DEV[@]}" 2>&1 | tail -3
  apt-get autoremove -y 2>&1 | tail -3
  apt-get clean
fi

# Purge local APT repo meta-packages (large but are just repo configs, not libs)
REPO_PACKAGES=(
  l4t-cuda-tegra-repo-ubuntu2204-12-6-local
  cudnn-local-tegra-repo-ubuntu2204-9.3.0
  nv-tensorrt-local-tegra-repo-ubuntu2204-10.3.0-cuda-12.5
)
INSTALLED_REPO=()
for pkg in "${REPO_PACKAGES[@]}"; do
  dpkg -l "$pkg" &>/dev/null 2>&1 && INSTALLED_REPO+=("$pkg")
done
if (( ${#INSTALLED_REPO[@]} > 0 )); then
  log "  Purging repo meta-packages: ${INSTALLED_REPO[*]}"
  apt-get purge -y "${INSTALLED_REPO[@]}" 2>&1 | tail -2
  apt-get clean
fi

log "Headless cleanup complete — dedicated Ollama inference node"

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
