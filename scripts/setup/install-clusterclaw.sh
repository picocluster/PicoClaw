#!/bin/bash
# install-clusterclaw.sh — Install full PicoCluster Claw stack on RPi5 via Docker
# Run on a golden image (after build-rpi5-image.sh + configure-pair.sh)
#
# Installs: OpenClaw (Docker), ThreadWeaver (Docker), Blinkt! LEDs (native),
#           Avahi mDNS (claw.local, threadweaver.local), Local CA + TLS (Caddy)
#
# Usage: sudo bash install-clusterclaw.sh [clustercrush-ip] [default-model] [openclaw-token]
set -euo pipefail

CRUSH_IP="${1:-10.1.10.221}"
# Ollama model tag — must support tool calling for ThreadWeaver MCP.
# llama3.1:8b is recommended; llama3.2:3b works for simple tasks.
# Other tool-capable models: phi3.5:3.8b, qwen2.5:3b, deepseek-r1:7b.
# Gemma3 and vision models do NOT support tool calling.
DEFAULT_MODEL="${2:-llama3.1:8b}"
OPENCLAW_TOKEN="${3:-picocluster-token}"
INSTALL_DIR="/opt/clusterclaw"
LED_DIR="$INSTALL_DIR/leds"
PKI_DIR="/opt/picocluster/pki"
USER="picocluster"

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== PicoCluster Claw Install (clusterclaw / RPi5) ==="
log "  clustercrush: ${CRUSH_IP}"
log "  Model: ${DEFAULT_MODEL}"
log ""

# ============================================================
# Set hostname + /etc/hosts aliases
# ============================================================
log "--- Hostname + /etc/hosts ---"
hostnamectl set-hostname clusterclaw
sed -i "s/127\.0\.1\.1.*/127.0.1.1\tclusterclaw/" /etc/hosts

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
10.1.10.220  clusterclaw clusterclaw.local claw claw.local threadweaver.local
10.1.10.221  clustercrush clustercrush.local crush crush.local
# END PICOCLUSTER CLAW
HOSTS
log "Hostname: clusterclaw (alias: claw)"

# ============================================================
# 0. Resize filesystem if needed
# ============================================================
DISK="/dev/mmcblk0"
PARTDEV="${DISK}p2"
DISK_SIZE=$(lsblk -b -n -o SIZE "$DISK" 2>/dev/null | head -1)
PART_SIZE=$(lsblk -b -n -o SIZE "$PARTDEV" 2>/dev/null | head -1)

if [[ -n "$DISK_SIZE" && -n "$PART_SIZE" ]]; then
  THRESHOLD=$(( DISK_SIZE * 90 / 100 ))
  if (( PART_SIZE < THRESHOLD )); then
    log "--- Step 0: Resizing filesystem ---"
    START_SECTOR=$(fdisk -l "$DISK" | grep "^${PARTDEV}" | awk '{print $2}')
    if [[ -n "$START_SECTOR" ]]; then
      fdisk "$DISK" <<EOF > /dev/null 2>&1
d
2
n
p
2
$START_SECTOR

w
EOF
      partprobe "$DISK"
      resize2fs "$PARTDEV"
      log "Filesystem resized: $(df -h / | awk 'NR==2 {print $2}')"
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
  "/home/${USER}/resize_rpi.sh"
  "/home/${USER}/resize_raspbian.sh"
  "/home/${USER}/restartAllNodes.sh"
  "/home/${USER}/stopAllNodes.sh"
  "/home/${USER}/testAllNodes.sh"
  "/home/${USER}/build-rpi5-image.sh"
  "/home/${USER}/install-clusterclaw.sh"
)
for f in "${LEGACY_FILES[@]}"; do
  [[ -f "$f" ]] && rm -f "$f" && log "  Removed $f"
done
[[ -d "/home/${USER}/.ansible" ]] && rm -rf "/home/${USER}/.ansible" && log "  Removed .ansible/"

# ============================================================
# 1. Docker
# ============================================================
log "--- Step 1/6: Docker ---"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$USER"
  systemctl enable docker
  log "Docker installed"
else
  log "Docker $(docker --version | awk '{print $3}') already installed"
fi

# ============================================================
# 2. Clone PicoCluster Claw repo
# ============================================================
log "--- Step 2/6: PicoCluster Claw repo ---"
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/picocluster/PicoCluster-Claw.git "$INSTALL_DIR"
  log "Repo cloned to $INSTALL_DIR"
else
  cd "$INSTALL_DIR" && git pull --ff-only 2>&1 | tail -3
  log "Repo updated"
fi

# ============================================================
# 3. Avahi mDNS — claw.local + threadweaver.local
# ============================================================
log "--- Step 3/6: Avahi mDNS ---"

# Install avahi + Python D-Bus bindings for CNAME alias publishing
if ! command -v avahi-daemon &>/dev/null; then
  apt-get install -y avahi-daemon avahi-utils libnss-mdns python3-avahi python3-dbus
  log "Avahi installed"
else
  apt-get install -y python3-avahi python3-dbus 2>/dev/null || true
  log "Avahi already installed"
fi

# Restrict Avahi to the physical LAN interface — prevents Docker bridge interfaces
# from confusing mDNS announcements and causing macOS to miss them
ETH_IF=$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|en)[0-9]/{print $2; exit}')
ETH_IF=${ETH_IF:-eth0}
if ! grep -q "^allow-interfaces" /etc/avahi/avahi-daemon.conf 2>/dev/null; then
  sed -i "s/^\[server\]/[server]\nallow-interfaces=${ETH_IF}/" /etc/avahi/avahi-daemon.conf
fi

# Clear /etc/avahi/hosts — CNAME aliases are published via the Python service
# below. A-records from /etc/avahi/hosts work on Linux but macOS Bonjour ignores
# them; CNAMEs pointing to the native hostname are followed on all platforms.
> /etc/avahi/hosts

systemctl enable avahi-daemon
systemctl restart avahi-daemon

# Install CNAME alias publisher
cp "$INSTALL_DIR/scripts/mdns-aliases.py" /usr/local/bin/picocluster-mdns-aliases
chmod +x /usr/local/bin/picocluster-mdns-aliases

cat > /etc/systemd/system/picocluster-mdns-aliases.service <<'UNIT'
[Unit]
Description=PicoClaw mDNS CNAME aliases (claw.local, threadweaver.local)
After=avahi-daemon.service
Requires=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/picocluster-mdns-aliases claw.local threadweaver.local
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable picocluster-mdns-aliases
systemctl restart picocluster-mdns-aliases
log "mDNS: claw.local, threadweaver.local → CNAME → clusterclaw.local (works on macOS)"

# ============================================================
# 4. PKI — Local CA + TLS certs for claw.local, threadweaver.local
# ============================================================
log "--- Step 4/6: PKI / TLS ---"
bash "$INSTALL_DIR/scripts/generate-pki.sh"

# ============================================================
# 5. Build and start Docker containers
# ============================================================
log "--- Step 5/6: Docker build + start ---"
cd "$INSTALL_DIR"

cat > "$INSTALL_DIR/.env" <<EOF
CRUSH_IP=${CRUSH_IP}
DEFAULT_MODEL=${DEFAULT_MODEL}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
EOF

# User-accessible file storage for OpenClaw and ThreadWeaver
FILES_DIR="/home/${USER}/claw-files"
mkdir -p "$FILES_DIR/openclaw" "$FILES_DIR/threadweaver"
chown -R "${USER}:${USER}" "$FILES_DIR"
log "File storage: $FILES_DIR (openclaw/, threadweaver/)"

# Verify PKI files exist before starting Caddy — it fails silently without them
PKI_DIR="/opt/picocluster/pki"
for cert in ca.crt claw.local.crt claw.local.key threadweaver.local.crt threadweaver.local.key; do
  if [[ ! -f "$PKI_DIR/$cert" ]]; then
    log "ERROR: PKI file missing: $PKI_DIR/$cert — re-running generate-pki.sh"
    bash "$INSTALL_DIR/scripts/generate-pki.sh"
    break
  fi
done

log "Pulling pre-built images and building local containers..."
docker compose pull threadweaver 2>&1 | tail -5
docker compose build openclaw portal 2>&1 | tail -10
docker compose up -d 2>&1
log "Containers started"

# ============================================================
# 6. Blinkt! LEDs (native — needs GPIO access)
# ============================================================
log "--- Step 6/6: Blinkt! LEDs ---"
apt-get install -y python3-gpiod 2>/dev/null || \
  pip3 install --break-system-packages gpiod 2>/dev/null || true

mkdir -p "$LED_DIR"
cp "$INSTALL_DIR/leds/apa102.py" "$LED_DIR/" 2>/dev/null || true
cp "$INSTALL_DIR/leds/clusterclaw_status.py" "$LED_DIR/" 2>/dev/null || true

if [[ -f "$INSTALL_DIR/leds/clusterclaw-leds.service" ]]; then
  cp "$INSTALL_DIR/leds/clusterclaw-leds.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable clusterclaw-leds
  systemctl start clusterclaw-leds
  log "Blinkt! LED daemon started"
else
  log "LED service file not found — skipping"
fi

# ============================================================
# Firewall
# ============================================================
log "--- Firewall ---"
ufw allow 5353/udp comment "mDNS (Avahi)"                          2>/dev/null || true
ufw allow 80/tcp   comment "PicoClaw portal + CA cert download"  2>/dev/null || true
ufw allow 443/tcp  comment "PicoClaw HTTPS (claw.local, threadweaver.local)" 2>/dev/null || true
ufw allow 7777/tcp comment "LED API"                              2>/dev/null || true
ufw allow 8888/tcp comment "Shutdown API"                         2>/dev/null || true

# Block internal ports — all raw HTTP is localhost-only via Docker
ufw deny 18789/tcp comment "OpenClaw raw HTTP (loopback only)"   2>/dev/null || true
ufw deny 18791/tcp comment "OpenClaw control"                    2>/dev/null || true
ufw deny 18792/tcp comment "OpenClaw CDP relay"                  2>/dev/null || true
ufw deny 5173/tcp  comment "ThreadWeaver UI (loopback only)"     2>/dev/null || true
ufw deny 8000/tcp  comment "ThreadWeaver API (loopback only)"    2>/dev/null || true

# Remove stale SSH-tunnel-era rules (18790, 5174 no longer needed — LAN uses HTTPS)
ufw delete allow 18790/tcp 2>/dev/null || true
ufw delete allow 5174/tcp  2>/dev/null || true

if [[ -f "$INSTALL_DIR/portal/shutdown-api.service" ]]; then
  cp "$INSTALL_DIR/portal/shutdown-api.service" /etc/systemd/system/
  echo "picocluster ALL=(ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot" \
    > /etc/sudoers.d/clusterclaw-shutdown
  chmod 440 /etc/sudoers.d/clusterclaw-shutdown
  systemctl daemon-reload
  systemctl enable shutdown-api
  systemctl start shutdown-api
  log "Shutdown API installed"
fi
log "Firewall configured"

# ============================================================
# User management scripts
# ============================================================
USER_BIN="/home/${USER}/bin"
if [[ -d "$INSTALL_DIR/scripts/user-bin/clusterclaw" ]]; then
  mkdir -p "$USER_BIN"
  cp "$INSTALL_DIR/scripts/user-bin/clusterclaw/"* "$USER_BIN/"
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
# Verify
# ============================================================
log ""
log "Waiting for services to start..."
sleep 10

log "=== Service Status ==="
docker compose ps 2>/dev/null
echo ""
log "  ThreadWeaver:  $(curl -sf --max-time 5 http://127.0.0.1:8000/api/settings  >/dev/null 2>&1 && echo 'OK' || echo 'STARTING')"
log "  OpenClaw:      $(curl -sf --max-time 5 http://127.0.0.1:18789/__openclaw__/health >/dev/null 2>&1 && echo 'OK' || echo 'STARTING')"
log "  Blinkt! LEDs:  $(systemctl is-active clusterclaw-leds 2>/dev/null || echo 'n/a')"
log "  Ollama:        $(curl -sf --max-time 5 http://${CRUSH_IP}:11434/api/tags >/dev/null 2>&1 && echo 'OK' || echo 'NOT REACHABLE')"
log "  Avahi:         $(systemctl is-active avahi-daemon 2>/dev/null)"
log "  CA cert:       $PKI_DIR/ca.crt $([ -f "$PKI_DIR/ca.crt" ] && echo '(exists)' || echo 'MISSING')"

log ""
log "============================================"
log "  PicoCluster Claw Install Complete"
log "============================================"
log ""
log "  Step 1 — Install CA cert on each client device:"
log "    Open in browser:  http://clusterclaw.local/ca.crt"
log "    (or by IP):       http://${CLAW_IP}/ca.crt"
log ""
log "  Step 2 — Access services (after CA cert installed):"
log "    OpenClaw:      https://claw.local"
log "    ThreadWeaver:  https://threadweaver.local"
log ""
log "  SSH tunnel (fallback, no CA cert needed):"
log "    ssh -L 5174:localhost:5174 -L 18790:localhost:18790 picocluster@clusterclaw"
log "    Then: https://localhost:18790  https://localhost:5174"
log ""
log "  Manage: cd $INSTALL_DIR && docker compose [up -d|down|logs|ps]"
log "  Update: cd $INSTALL_DIR && git pull && docker compose build --pull && docker compose up -d"
log "============================================"
