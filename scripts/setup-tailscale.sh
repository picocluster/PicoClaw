#!/usr/bin/env bash
# setup-tailscale.sh — Install Tailscale on PicoClaw for remote/cross-network access.
# Run on clusterclaw (RPi5) as root.
#
# Tailscale gives the cluster a stable hostname and IP accessible from anywhere —
# no port forwarding, no VPN config, works through NAT and firewalls.
# It is entirely optional; mDNS (claw.local / threadweaver.local / control.local) handles LAN access.
#
# Usage:
#   sudo bash scripts/setup-tailscale.sh [OPTIONS]
#
# Options:
#   --authkey  <key>   Tailscale auth key (from tailscale.com/admin/settings/keys)
#                      Skip for interactive login (browser link printed to console)
#   --ssh-crush        Also install Tailscale on clustercrush via SSH
#   --advertise-exit   Advertise this node as a Tailscale exit node (optional)
#   --dry-run          Show what would run without applying
#
# Examples:
#   # Interactive — follow the printed URL to authenticate
#   sudo bash scripts/setup-tailscale.sh
#
#   # Automated with auth key (good for pre-ship provisioning)
#   sudo bash scripts/setup-tailscale.sh --authkey tskey-auth-xxxxxxxxxxxx
#
#   # Install on both nodes
#   sudo bash scripts/setup-tailscale.sh --authkey tskey-auth-xxxxxxxxxxxx --ssh-crush

set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

AUTH_KEY=""
SSH_CRUSH=false
ADVERTISE_EXIT=false
DRY_RUN=false
CRUSH_IP=$(grep '^CRUSH_IP=' /opt/clusterclaw/.env 2>/dev/null | cut -d= -f2 || echo "10.1.10.221")
CRUSH_SSH_USER="picocluster"

while [[ $# -gt 0 ]]; do
    case $1 in
        --authkey)        AUTH_KEY="$2";      shift 2 ;;
        --ssh-crush)      SSH_CRUSH=true;     shift ;;
        --advertise-exit) ADVERTISE_EXIT=true; shift ;;
        --dry-run)        DRY_RUN=true;        shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log()   { echo "[$(date '+%H:%M:%S')] $*"; }
apply() { $DRY_RUN && echo "  [dry-run] $*" || eval "$*"; }

echo "=== PicoClaw Tailscale Setup ==="
$DRY_RUN && echo "  (dry-run — no changes applied)"
echo ""

# ---------------------------------------------------------------------------
# 1. Install Tailscale
# ---------------------------------------------------------------------------
log "--- Install Tailscale ---"
if command -v tailscale &>/dev/null; then
    log "Tailscale already installed: $(tailscale version | head -1)"
else
    apply "curl -fsSL https://tailscale.com/install.sh | sh"
    apply "systemctl enable tailscaled"
    apply "systemctl start tailscaled"
    log "Tailscale installed"
fi

# ---------------------------------------------------------------------------
# 2. Bring up Tailscale
# ---------------------------------------------------------------------------
log "--- Bring up Tailscale ---"

UP_ARGS=""
[ -n "$AUTH_KEY" ]     && UP_ARGS="$UP_ARGS --authkey=$AUTH_KEY"
$ADVERTISE_EXIT        && UP_ARGS="$UP_ARGS --advertise-exit-node"

# --ssh enables Tailscale SSH (optional but useful for remote management)
UP_ARGS="$UP_ARGS --ssh"

apply "tailscale up $UP_ARGS"

# ---------------------------------------------------------------------------
# 3. Report Tailscale status
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    sleep 2
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "(pending auth)")
    TS_NAME=$(tailscale status --json 2>/dev/null | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" \
      2>/dev/null || echo "(pending auth)")
    log "Tailscale IP:   ${TS_IP}"
    log "Tailscale name: ${TS_NAME}"
fi

# ---------------------------------------------------------------------------
# 4. Open Tailscale IP in firewall (Caddy already on host network — reachable)
# ---------------------------------------------------------------------------
log "--- Firewall ---"
apply "ufw allow in on tailscale0 to any port 443 comment 'HTTPS via Tailscale' 2>/dev/null || true"
apply "ufw allow in on tailscale0 to any port 80  comment 'HTTP/CA cert via Tailscale' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 5. Optionally install on clustercrush via SSH
# ---------------------------------------------------------------------------
if $SSH_CRUSH; then
    log "--- Installing Tailscale on clustercrush (${CRUSH_IP}) ---"
    CRUSH_SCRIPT="curl -fsSL https://tailscale.com/install.sh | sh && systemctl enable tailscaled && systemctl start tailscaled"
    [ -n "$AUTH_KEY" ] && CRUSH_SCRIPT="${CRUSH_SCRIPT} && tailscale up --authkey=${AUTH_KEY} --ssh"

    if $DRY_RUN; then
        echo "  [dry-run] would SSH to ${CRUSH_SSH_USER}@${CRUSH_IP} and run:"
        echo "    $CRUSH_SCRIPT"
    else
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${CRUSH_SSH_USER}@${CRUSH_IP}" "sudo bash -c '${CRUSH_SCRIPT}'" || \
            log "WARNING: SSH to clustercrush failed — install Tailscale there manually"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Tailscale Setup Complete"
echo "============================================"
echo ""
if [ -n "$AUTH_KEY" ]; then
    echo "  Node is authenticated and connected."
    echo ""
    echo "  Access from anywhere (Tailscale connected device):"
    TS_IP_FINAL=$(tailscale ip -4 2>/dev/null || echo "<tailscale-ip>")
    echo "    OpenClaw:      https://claw.local  (LAN) or https://${TS_IP_FINAL} (remote)"
    echo "    ThreadWeaver:  https://threadweaver.local  (LAN) or https://${TS_IP_FINAL}:5173 (remote)"
    echo "    Portal:        http://${TS_IP_FINAL}"
    echo ""
    echo "  Tailscale admin:  https://tailscale.com/admin"
else
    echo "  Complete authentication — visit the URL printed above in a browser."
    echo "  Then re-run:  tailscale status"
    echo ""
    echo "  Once authenticated, access via Tailscale IP or MagicDNS name."
fi
echo ""
echo "  To check status:   tailscale status"
echo "  To disconnect:     tailscale down"
echo "  To uninstall:      tailscale down && apt-get remove tailscale"
echo "============================================"
