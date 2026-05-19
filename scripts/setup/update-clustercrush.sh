#!/bin/bash
# update-clustercrush.sh — Update PicoCluster Claw software on Orin Nano
# Usage: sudo bash update-clustercrush.sh [component]
#        sudo bash update-clustercrush.sh             # Update Ollama + pull models
#        sudo bash update-clustercrush.sh ollama       # Update Ollama only
#        sudo bash update-clustercrush.sh models       # Pull any missing default models
#        sudo bash update-clustercrush.sh services     # Re-apply headless service config
#        sudo bash update-clustercrush.sh pull <model> # Pull a specific model
set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

COMPONENT="${1:-all}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Models validated to work with OpenClaw on Jetson Orin Nano 8GB.
# Listed in order of benchmark performance (best first).
# Large models (>8B params) are excluded — they cannot cold-load within
# reasonable time on 8GB unified memory.
DEFAULT_MODELS=(
  "granite4.1:8b"       # Best overall agent performance (6/6 T1+T2)
  "nemotron-3-nano:4b"  # Best small model (5/10 full suite)
  "llama3.2:3b"         # Fast; good T1 reasoning, tool use limited
  "qwen3.5:4b"          # Default for OpenClaw UI; slow but functional
  "llama3.1:8b"         # Decent reasoning; tool hallucination issues
  "phi3.5:3.8b"         # T1 inference only — tool schema incompatible
  "deepseek-r1:7b"      # Inference only — no tool/function call support
  "gemma4:e4b"          # 9.6GB — requires pre-warming; slow cold load
)

update_ollama() {
  log "Updating Ollama..."
  curl -fsSL https://ollama.ai/install.sh | sh
  systemctl restart ollama
  sleep 3
  log "Ollama $(ollama --version 2>/dev/null)"
}

update_models() {
  log "Pulling default models..."
  for model in "${DEFAULT_MODELS[@]}"; do
    log "  $model..."
    ollama pull "$model" 2>&1 | tail -1
  done
}

update_services() {
  log "Re-applying headless service configuration..."
  DISABLE_SERVICES=(
    fail2ban ModemManager rpcbind seatd haveged
    nvargus-daemon nvweston nvfb nvfb-early nvfb-udev nvgetty
    unattended-upgrades wpa_supplicant
  )
  for svc in "${DISABLE_SERVICES[@]}"; do
    systemctl disable --now "$svc" 2>/dev/null || true
  done
  systemctl disable --now docker.socket rpcbind.socket 2>/dev/null || true
  if systemctl is-active --quiet docker 2>/dev/null; then
    systemctl disable --now docker containerd 2>/dev/null || true
  fi
  log "Services updated"
}

case "$COMPONENT" in
  all)
    update_ollama
    update_models
    ;;
  ollama)
    update_ollama
    ;;
  models)
    update_models
    ;;
  services)
    update_services
    ;;
  pull)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 pull <model>"
      echo "Example: $0 pull gemma2:2b"
      exit 1
    fi
    ollama pull "$2"
    ;;
  *)
    echo "Usage: $0 [all|ollama|models|services|pull <model>]"
    exit 1
    ;;
esac

log ""
log "=== Status ==="
log "  Ollama: $(systemctl is-active ollama)"
log "  Models:"
ollama list 2>&1 | sed 's/^/    /'
