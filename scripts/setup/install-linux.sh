#!/bin/bash
# install-linux.sh — Install PicoCluster Claw on a Linux PC / server
# Runs the same Docker stack as the cluster variant, with Ollama native (GPU or CPU).
# Supports Ubuntu 22.04/24.04 and Debian 12+.
#
# Usage: bash install-linux.sh [model] [--tier large|--tier small]
#   model: default Ollama model (default: qwen3.5:4b — matches the appliance)
#   --tier large : also pull 14B-class models (auto-prompted on 16 GB+ devices)
#   --tier small : skip the large-tier prompt
set -euo pipefail

DEFAULT_MODEL="${1:-qwen3.5:4b}"
INSTALL_DIR="${HOME}/picocluster-claw"
OPENCLAW_TOKEN="picocluster-token"

# 8 GB-tier model set — matches the Claw appliance catalog so the desktop
# install behaves identically to the boxed hardware.
MODELS=(
  "qwen3.5:4b"
  "qwen3.5:9b"
  "granite4.1:8b"
  "llama3.1:8b"
  "deepseek-r1:7b"
  "ministral-3:8b"
  "nemotron-3-nano:4b"
  "phi3.5:3.8b"
  "llama3.2:3b"
  "gemma4:e4b"
)

# 16 GB+ tier — larger siblings of the same families. Opt-in: prompted
# automatically when the device has >= 16 GB of system memory.
LARGE_MODELS=(
  "qwen3.5:14b"
  "deepseek-r1:14b"
  "phi-4:14b"
)

# Allow non-interactive override: --tier large | --tier small
TIER_OVERRIDE=""
for arg in "$@"; do
  case "$arg" in
    --tier=large|--tier=small) TIER_OVERRIDE="${arg#--tier=}" ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== PicoCluster Claw — Linux Solo Install ==="
log "  Model: ${DEFAULT_MODEL}"
log "  Install dir: ${INSTALL_DIR}"
log ""

# ============================================================
# 1. Prerequisites
# ============================================================
log "--- Step 1/6: Prerequisites ---"

# OS check
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
  log "WARNING: This installer is tested on Ubuntu/Debian. Continuing anyway..."
fi
log "  OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
log "  Arch: $(uname -m)"

# Docker
if ! command -v docker &>/dev/null; then
  log "  Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  log "  Docker installed. You may need to log out and back in for group changes."
  log "  If docker commands fail, run: newgrp docker"
else
  log "  Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'installed')"
fi

if ! docker info &>/dev/null 2>&1; then
  log "  ERROR: Docker is installed but not running."
  log "  >>> sudo systemctl start docker && sudo systemctl enable docker <<<"
  exit 1
fi

# Ollama
if ! command -v ollama &>/dev/null; then
  log "  Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
log "  Ollama: $(ollama --version 2>/dev/null || echo 'installed')"

# GPU detection (informational)
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
  GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  log "  GPU (NVIDIA): ${GPU}"
elif command -v rocm-smi &>/dev/null; then
  log "  GPU: AMD ROCm detected"
else
  log "  GPU: none detected — Ollama will use CPU"
fi

# ============================================================
# 2. Ollama setup
# ============================================================
log "--- Step 2/6: Ollama ---"

if ! systemctl is-active --quiet ollama 2>/dev/null; then
  log "  Starting Ollama service..."
  sudo systemctl enable ollama 2>/dev/null || true
  sudo systemctl start ollama 2>/dev/null || true
fi

for i in $(seq 1 30); do
  if curl -sf --max-time 2 http://localhost:11434/api/tags &>/dev/null; then
    log "  Ollama ready (attempt $i)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    log "  ERROR: Ollama failed to start after 30 attempts"
    exit 1
  fi
  sleep 2
done

# ============================================================
# 3. Pull models
# ============================================================
log "--- Step 3/6: Pull models ---"

# Decide whether to pull the 16 GB+ large tier.
RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
RAM_GB=$(( RAM_KB / 1024 / 1024 ))
PULL_LARGE=0

if [[ "$TIER_OVERRIDE" == "large" ]]; then
  PULL_LARGE=1
  log "  Tier: large (forced via --tier=large)"
elif [[ "$TIER_OVERRIDE" == "small" ]]; then
  log "  Tier: small (forced via --tier=small) — skipping large models"
elif [[ "$RAM_GB" -ge 16 ]]; then
  log "  Detected ${RAM_GB} GB RAM — large 14B-class models will fit."
  read -r -p "  Pull large-tier models too (qwen3.5:14b, deepseek-r1:14b, phi-4:14b)? [y/N] " reply </dev/tty || reply=""
  reply_lc=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
  if [[ "$reply_lc" == "y" || "$reply_lc" == "yes" ]]; then
    PULL_LARGE=1
  fi
else
  log "  Detected ${RAM_GB} GB RAM — staying on 8 GB-tier models."
fi

for model in "${MODELS[@]}"; do
  log "  Pulling $model..."
  ollama pull "$model" 2>&1 | tail -1
done

if [[ "$PULL_LARGE" -eq 1 ]]; then
  log "--- Pulling large-tier models (16 GB+) ---"
  for model in "${LARGE_MODELS[@]}"; do
    log "  Pulling $model..."
    ollama pull "$model" 2>&1 | tail -1
  done
fi

log "  Installed models:"
ollama list 2>&1 | tail -n +2 | awk '{printf "    %s (%s)\n", $1, $3$4}'

# ============================================================
# 4. Clone repo + Docker
# ============================================================
log "--- Step 4/6: PicoCluster Claw repo + Docker ---"

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/picocluster/PicoCluster-Claw.git "$INSTALL_DIR"
  log "  Repo cloned"
else
  cd "$INSTALL_DIR" && git pull --ff-only 2>&1 | tail -3
  log "  Repo updated"
fi

# User file directories
mkdir -p "${HOME}/claw-files/threadweaver" "${HOME}/claw-files/openclaw"

# Write .env
cat > "$INSTALL_DIR/.env" <<ENV
CRUSH_IP=127.0.0.1
DEFAULT_MODEL=${DEFAULT_MODEL}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
ENV

cd "$INSTALL_DIR"
log "  Pulling ThreadWeaver image from GHCR..."
docker compose -f docker-compose.yml -f docker-compose.linux.yml pull threadweaver 2>&1 | tail -5
log "  Building local containers..."
docker compose -f docker-compose.yml -f docker-compose.linux.yml build openclaw portal 2>&1 | tail -5
log "  Starting containers..."
docker compose -f docker-compose.yml -f docker-compose.linux.yml up -d threadweaver openclaw portal 2>&1 | tail -10

# Wait for ThreadWeaver frontend
log "  Waiting for services..."
for i in $(seq 1 30); do
  if curl -sf --max-time 2 http://127.0.0.1:5173/ &>/dev/null; then
    log "  ThreadWeaver ready"
    break
  fi
  sleep 3
done

# ============================================================
# 5. User scripts
# ============================================================
log "--- Step 5/6: User scripts ---"
USER_BIN="${HOME}/bin"
mkdir -p "$USER_BIN"

if [[ -d "$INSTALL_DIR/scripts/user-bin/linux" ]]; then
  cp "$INSTALL_DIR/scripts/user-bin/linux/"* "$USER_BIN/" 2>/dev/null
  chmod +x "$USER_BIN/"*
  log "  Installed Linux scripts: $(ls "$USER_BIN"/pc-* 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
else
  cp "$INSTALL_DIR/scripts/user-bin/clusterclaw/"* "$USER_BIN/" 2>/dev/null
  chmod +x "$USER_BIN/"*
  log "  Installed scripts (cluster variant): $(ls "$USER_BIN"/pc-* 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
fi

SHELL_RC="${HOME}/.bashrc"
[[ "$SHELL" == */zsh ]] && SHELL_RC="${HOME}/.zshrc"
if ! grep -q 'HOME/bin' "$SHELL_RC" 2>/dev/null; then
  cat >> "$SHELL_RC" <<'SHELLRC'

# PicoCluster Claw user scripts
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi
SHELLRC
  log "  Added ~/bin to PATH in ${SHELL_RC}"
fi

# ============================================================
# 6. Verify
# ============================================================
log "--- Step 6/6: Verify ---"

log "  Docker containers:"
docker ps --format '    {{.Names}}: {{.Status}}'

log ""
TW_OK=$(curl -sf --max-time 5 http://127.0.0.1:5173/ >/dev/null 2>&1 && echo "OK" || echo "FAIL")
OC_OK=$(curl -sf --max-time 5 http://127.0.0.1:18789/__openclaw__/health >/dev/null 2>&1 && echo "OK" || echo "FAIL")
OL_OK=$(curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1 && echo "OK" || echo "FAIL")
PT_OK=$(curl -sf --max-time 5 http://localhost:80/ >/dev/null 2>&1 && echo "OK" || echo "FAIL")

log "  ThreadWeaver: ${TW_OK}"
log "  OpenClaw:     ${OC_OK}"
log "  Ollama:       ${OL_OK}"
log "  Portal:       ${PT_OK}"

TOOLS=$(curl -sf http://127.0.0.1:18789/__openclaw__/tools 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
log "  MCP Tools:    ${TOOLS}"

log ""
log "============================================"
log "  PicoCluster Claw — Linux Solo Install Complete"
log "============================================"
log ""
log "  ThreadWeaver:  http://localhost:5173"
log "  OpenClaw:      http://localhost:18789"
log "  Portal:        http://localhost/"
log "  Ollama:        http://localhost:11434"
log ""
log "  Docker commands:"
log "    cd ${INSTALL_DIR}"
log "    docker compose -f docker-compose.yml -f docker-compose.linux.yml [up -d|down|logs|ps]"
log ""
log "  Manage models:"
log "    ollama list              # Show installed models"
log "    ollama pull <model>      # Download a model"
log "    ollama rm <model>        # Remove a model"
log "    systemctl status ollama  # Check Ollama service"
log "============================================"
