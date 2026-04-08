#!/bin/bash
# update-picoclaw.sh — Update PicoClaw software on RPi5
# Usage: sudo bash update-picoclaw.sh [component]
#        sudo bash update-picoclaw.sh           # Update all
#        sudo bash update-picoclaw.sh openclaw   # Update OpenClaw only
#        sudo bash update-picoclaw.sh threadweaver
set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

COMPONENT="${1:-all}"
TW_DIR="/opt/picoclcaw/threadweaver"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

update_openclaw() {
  log "Updating OpenClaw..."
  BEFORE=$(openclaw --version 2>/dev/null || echo "not installed")
  npm update -g openclaw 2>&1 | tail -3
  AFTER=$(openclaw --version 2>/dev/null)
  systemctl restart openclaw
  log "OpenClaw: $BEFORE → $AFTER"
}

update_threadweaver() {
  log "Updating ThreadWeaver..."
  cd "$TW_DIR"

  # Save local patches
  git stash 2>/dev/null || true
  git pull --ff-only 2>&1 | tail -3

  # Re-apply patches
  sed -i "s|const API_BASE = 'http://localhost:8000/api'|const API_BASE = '/api'|g" \
    "$TW_DIR/frontend/src/lib/api.ts" \
    "$TW_DIR/frontend/src/routes/+page.svelte" 2>/dev/null

  # Update dependencies
  cd "$TW_DIR/backend"
  "$TW_DIR/venv/bin/pip" install --no-cache-dir -r requirements.txt 2>&1 | tail -3

  cd "$TW_DIR/frontend"
  npm install 2>&1 | tail -3

  # Re-apply llama-server patch
  for patch in /home/picocluster/threadweaver/patch-llama-server.py /opt/picoclcaw/threadweaver/patch-llama-server.py; do
    if [[ -f "$patch" ]]; then
      python3 "$patch" "$TW_DIR/backend/server.py"
      break
    fi
  done

  chown -R picocluster:picocluster "$TW_DIR"
  systemctl restart threadweaver
  log "ThreadWeaver updated and restarted"
}

update_leds() {
  log "Updating LED daemon..."
  systemctl restart picoclaw-leds 2>/dev/null || log "LED service not installed"
  log "LED daemon restarted"
}

case "$COMPONENT" in
  all)
    update_openclaw
    update_threadweaver
    update_leds
    ;;
  openclaw)
    update_openclaw
    ;;
  threadweaver)
    update_threadweaver
    ;;
  leds)
    update_leds
    ;;
  *)
    echo "Usage: $0 [all|openclaw|threadweaver|leds]"
    exit 1
    ;;
esac

log ""
log "=== Update complete ==="
log "  OpenClaw:     $(systemctl is-active openclaw)"
log "  ThreadWeaver: $(systemctl is-active threadweaver)"
log "  Blinkt LEDs:  $(systemctl is-active picoclaw-leds 2>/dev/null || echo 'n/a')"
