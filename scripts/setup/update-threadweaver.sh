#!/bin/bash
# update-threadweaver.sh — Check for and apply ThreadWeaver updates
# Usage: sudo bash update-threadweaver.sh          # Check and update if new
#        sudo bash update-threadweaver.sh --force   # Force rebuild
set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

INSTALL_DIR="/opt/picoclcaw"
FORCE="${1:-}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Get current version (commit hash baked into running container)
CURRENT=$(docker exec threadweaver sh -c 'cd /app && git rev-parse --short HEAD 2>/dev/null' 2>/dev/null || echo "unknown")
CURRENT_DATE=$(docker exec threadweaver sh -c 'cd /app && git log -1 --format=%ci 2>/dev/null' 2>/dev/null || echo "unknown")

# Get latest version from GitHub
LATEST=$(git ls-remote --heads https://github.com/nosqltips/ThreadWeaver.git main | cut -c1-7 2>/dev/null || echo "unknown")

log "Current:  $CURRENT ($CURRENT_DATE)"
log "Latest:   $LATEST"

if [[ "$CURRENT" == "$LATEST" && "$FORCE" != "--force" ]]; then
  log "Already up to date. Use --force to rebuild anyway."
  exit 0
fi

if [[ "$CURRENT" == "unknown" ]]; then
  log "Could not determine current version — rebuilding."
elif [[ "$LATEST" == "unknown" ]]; then
  log "Could not check latest version — rebuilding anyway."
else
  log "New version available: $CURRENT → $LATEST"
fi

log "Updating PicoClaw repo..."
cd "$INSTALL_DIR"
git fetch origin && git reset --hard origin/main 2>&1 | tail -1

log "Rebuilding ThreadWeaver..."
docker compose build --no-cache threadweaver 2>&1 | tail -5
docker compose up -d threadweaver 2>&1

sleep 5
NEW=$(docker exec threadweaver sh -c 'cd /app && git rev-parse --short HEAD 2>/dev/null' 2>/dev/null || echo "unknown")
NEW_DATE=$(docker exec threadweaver sh -c 'cd /app && git log -1 --format=%ci 2>/dev/null' 2>/dev/null || echo "unknown")

log ""
log "=== Update complete ==="
log "  Version: $NEW ($NEW_DATE)"
log "  Status:  $(docker inspect threadweaver --format '{{.State.Status}}' 2>/dev/null)"
log "  Health:  $(curl -sf --max-time 5 http://127.0.0.1:8000/api/settings >/dev/null && echo 'OK' || echo 'STARTING')"
