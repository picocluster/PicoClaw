#!/usr/bin/env bash
# network-config.sh — Reconfigure PicoClaw network settings across the full stack.
# Run on the RPi5 (clusterclaw) as root after changing IPs.
#
# Updates: .env, /etc/hosts (claw), /etc/avahi/hosts, Docker services,
#          and optionally SSHes to clustercrush to sync /etc/hosts + firewall.
#
# Usage:
#   sudo bash scripts/network-config.sh [OPTIONS]
#
# Options:
#   --claw-ip   <ip>    RPi5 IP address      (required for host changes)
#   --crush-ip  <ip>    Orin IP address      (default: current value in .env)
#   --gateway   <ip>    Gateway IP           (for info only, not applied here)
#   --domain    <sfx>   mDNS domain suffix   (default: local)
#   --ssh-crush         SSH to clustercrush to sync /etc/hosts + firewall
#   --dry-run           Show changes without applying them
#
# Examples:
#   # Move entire cluster to 192.168.1.x
#   sudo bash scripts/network-config.sh --claw-ip 192.168.1.50 --crush-ip 192.168.1.51 --ssh-crush
#
#   # Only update crush IP (e.g. after DHCP reassigned it)
#   sudo bash scripts/network-config.sh --crush-ip 192.168.1.51
#
#   # Dry run to preview
#   sudo bash scripts/network-config.sh --claw-ip 192.168.1.50 --crush-ip 192.168.1.51 --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
AVAHI_HOSTS="/etc/avahi/hosts"
CRUSH_SSH_USER="picocluster"

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
NEW_CLAW_IP=""
NEW_CRUSH_IP=""
GATEWAY=""
DOMAIN="local"
SSH_CRUSH=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --claw-ip)   NEW_CLAW_IP="$2";  shift 2 ;;
        --crush-ip)  NEW_CRUSH_IP="$2"; shift 2 ;;
        --gateway)   GATEWAY="$2";      shift 2 ;;
        --domain)    DOMAIN="$2";       shift 2 ;;
        --ssh-crush) SSH_CRUSH=true;    shift ;;
        --dry-run)   DRY_RUN=true;      shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Read current values from .env
# ---------------------------------------------------------------------------
cur_crush_ip() { grep '^CRUSH_IP=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo ""; }

CRUSH_IP="${NEW_CRUSH_IP:-$(cur_crush_ip)}"
CLAW_IP="${NEW_CLAW_IP:-}"

log()   { echo "  [net] $*"; }
apply() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        eval "$*"
    fi
}

echo "=== PicoClaw Network Config ==="
echo "  claw IP   = ${CLAW_IP:-(unchanged)}"
echo "  crush IP  = $CRUSH_IP"
echo "  domain    = $DOMAIN"
$DRY_RUN && echo "  (dry-run — no changes applied)"
echo ""

# ---------------------------------------------------------------------------
# 1. Update .env (CRUSH_IP)
# ---------------------------------------------------------------------------
log "Updating $ENV_FILE ..."
apply "sed -i 's|^CRUSH_IP=.*|CRUSH_IP=${CRUSH_IP}|' \"$ENV_FILE\""

# ---------------------------------------------------------------------------
# 2. Update /etc/hosts on claw
# ---------------------------------------------------------------------------
CLAW_HOST_IP="${CLAW_IP:-10.1.10.220}"
CRUSH_HOST_IP="$CRUSH_IP"

log "Updating /etc/hosts ..."
apply "sed -i '/# BEGIN PICOCLUSTER CLAW/,/# END PICOCLUSTER CLAW/d' /etc/hosts"
apply "printf '\n# BEGIN PICOCLUSTER CLAW\n%s  clusterclaw claw\n%s  clustercrush crush\n# END PICOCLUSTER CLAW\n' \
  '${CLAW_HOST_IP}' '${CRUSH_HOST_IP}' >> /etc/hosts"

# ---------------------------------------------------------------------------
# 3. Update /etc/avahi/hosts (claw.local + threadweaver.local aliases)
# ---------------------------------------------------------------------------
if [ -n "$CLAW_IP" ] && [ -f "$AVAHI_HOSTS" ]; then
    log "Updating $AVAHI_HOSTS ..."
    apply "cat > \"$AVAHI_HOSTS\" <<'EOF'
# PicoClaw mDNS aliases — managed by network-config.sh
${CLAW_IP}  claw.${DOMAIN}
${CLAW_IP}  threadweaver.${DOMAIN}
EOF"
    apply "systemctl restart avahi-daemon"
fi

# ---------------------------------------------------------------------------
# 4. Restart Docker services to pick up new .env
# ---------------------------------------------------------------------------
log "Restarting Docker services ..."
apply "cd \"$REPO_DIR\" && docker compose up -d"

# ---------------------------------------------------------------------------
# 5. SSH to clustercrush to sync /etc/hosts + firewall (optional)
# ---------------------------------------------------------------------------
if $SSH_CRUSH && [ -n "$CLAW_IP" ]; then
    log "SSHing to clustercrush (${CRUSH_IP}) to sync /etc/hosts and firewall ..."
    CRUSH_SYNC=$(cat <<REMOTE
set -e
# Update /etc/hosts
sed -i '/# BEGIN PICOCLUSTER CLAW/,/# END PICOCLUSTER CLAW/d' /etc/hosts
printf '\n# BEGIN PICOCLUSTER CLAW\n%s  clusterclaw claw\n%s  clustercrush crush\n# END PICOCLUSTER CLAW\n' \
  '${CLAW_IP}' '${CRUSH_IP}' >> /etc/hosts
# Update firewall — allow new claw IP, remove stale rules
ufw delete allow from 0.0.0.0/0 to any port 11434 2>/dev/null || true
ufw allow from '${CLAW_IP}' to any port 11434 comment 'Ollama from clusterclaw' 2>/dev/null || true
echo "clustercrush /etc/hosts and firewall updated"
REMOTE
)
    if $DRY_RUN; then
        echo "  [dry-run] would SSH to ${CRUSH_SSH_USER}@${CRUSH_IP} and run:"
        echo "$CRUSH_SYNC" | sed 's/^/    /'
    else
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${CRUSH_SSH_USER}@${CRUSH_IP}" "sudo bash -s" <<< "$CRUSH_SYNC" || \
            echo "  WARNING: SSH to clustercrush failed — update /etc/hosts and firewall manually"
    fi
fi

echo ""
echo "Done."
[ -n "$CLAW_IP" ] && echo "  CA cert:        http://clusterclaw.${DOMAIN}/ca.crt"
echo "  OpenClaw:       https://claw.${DOMAIN}"
echo "  ThreadWeaver:   https://threadweaver.${DOMAIN}"
