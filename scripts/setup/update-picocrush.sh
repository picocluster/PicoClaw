#!/bin/bash
# update-picocrush.sh — Update PicoClaw software on Orin Nano
# Usage: sudo bash update-picocrush.sh [component]
#        sudo bash update-picocrush.sh             # Update all
#        sudo bash update-picocrush.sh llama        # Rebuild llama.cpp only
#        sudo bash update-picocrush.sh models       # Download any missing models
#        sudo bash update-picocrush.sh add-model URL # Add a new model from URL
set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

COMPONENT="${1:-all}"
LLAMA_DIR="/mnt/nvme/llama.cpp"
MODEL_DIR="/mnt/nvme/models"
USER="picocluster"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

update_llama() {
  log "Updating llama.cpp..."
  cd "$LLAMA_DIR"
  sudo -u "$USER" git pull --ff-only 2>&1 | tail -3
  cd build
  log "Rebuilding (this takes ~10 minutes)..."
  sudo -u "$USER" cmake .. -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87
  sudo -u "$USER" make -j$(nproc) 2>&1 | tail -5
  systemctl restart llama-server
  # Wait for health
  for i in $(seq 1 30); do
    if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q '"ok"'; then
      log "llama-server restarted and healthy"
      return
    fi
    sleep 2
  done
  log "WARNING: llama-server may not be healthy"
}

update_models() {
  log "Checking models..."
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
}

add_model() {
  local url="$1"
  local filename=$(basename "$url")
  log "Downloading $filename..."
  sudo -u "$USER" wget -q --show-progress -O "$MODEL_DIR/$filename" "$url"
  log "Downloaded to $MODEL_DIR/$filename"
  log "Switch to it with: sudo model-switch $filename"
  model-switch --list
}

case "$COMPONENT" in
  all)
    update_llama
    update_models
    ;;
  llama)
    update_llama
    ;;
  models)
    update_models
    ;;
  add-model)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 add-model <huggingface-url>"
      echo "Example: $0 add-model https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
      exit 1
    fi
    add_model "$2"
    ;;
  *)
    echo "Usage: $0 [all|llama|models|add-model URL]"
    exit 1
    ;;
esac

log ""
log "=== Update complete ==="
log "  llama-server: $(systemctl is-active llama-server)"
log "  Active model: $(grep -oP '(?<=--model )\S+' /etc/systemd/system/llama-server.service | xargs basename)"
log "  Available models:"
model-switch --list 2>/dev/null | grep "    \|  \*" || ls "$MODEL_DIR"/*.gguf 2>/dev/null
