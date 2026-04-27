#!/usr/bin/env bash
# set-network.sh — Switch PicoClaw network interface between static IP and DHCP.
# Run on the target node (clusterclaw or clustercrush) as root.
#
# Works with Raspberry Pi OS (dhcpcd), Ubuntu/Debian (NetworkManager or netplan).
#
# Usage:
#   sudo bash scripts/set-network.sh static --ip <ip> --gateway <gw> [OPTIONS]
#   sudo bash scripts/set-network.sh dhcp   [OPTIONS]
#
# Options:
#   --iface   <name>   Network interface  (default: auto-detected)
#   --ip      <ip>     Static IP (with prefix, e.g. 192.168.1.50/24)
#   --gateway <ip>     Default gateway
#   --dns     <ip>     DNS server         (default: 1.1.1.1)
#   --dry-run          Show changes without applying
#
# Examples:
#   # Set static IP on claw
#   sudo bash scripts/set-network.sh static --ip 10.1.10.220/24 --gateway 10.1.10.1
#
#   # Switch to DHCP (e.g. for plug-and-play on user's network)
#   sudo bash scripts/set-network.sh dhcp
#
#   # Preview only
#   sudo bash scripts/set-network.sh dhcp --dry-run

set -euo pipefail

if (( EUID != 0 )); then
  echo "ERROR: Must run as root"
  exit 1
fi

MODE="${1:-}"
if [[ "$MODE" != "static" && "$MODE" != "dhcp" ]]; then
    echo "Usage: sudo bash set-network.sh <static|dhcp> [OPTIONS]"
    exit 1
fi
shift

IFACE=""
STATIC_IP=""
GATEWAY=""
DNS="1.1.1.1"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --iface)   IFACE="$2";     shift 2 ;;
        --ip)      STATIC_IP="$2"; shift 2 ;;
        --gateway) GATEWAY="$2";   shift 2 ;;
        --dns)     DNS="$2";       shift 2 ;;
        --dry-run) DRY_RUN=true;   shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Auto-detect primary ethernet interface
if [ -z "$IFACE" ]; then
    IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -z "$IFACE" ] && IFACE=$(ls /sys/class/net | grep -E '^eth|^en' | head -1)
    [ -z "$IFACE" ] && { echo "ERROR: Could not detect network interface. Use --iface."; exit 1; }
fi

log()   { echo "  [net] $*"; }
apply() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        eval "$*"
    fi
}

echo "=== PicoClaw Network: $MODE ==="
echo "  Interface: $IFACE"
[ "$MODE" = "static" ] && echo "  IP:        $STATIC_IP"
[ "$MODE" = "static" ] && echo "  Gateway:   $GATEWAY"
$DRY_RUN && echo "  (dry-run)"
echo ""

# Detect network manager
detect_nm() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "NetworkManager"
    elif [ -f /etc/dhcpcd.conf ]; then
        echo "dhcpcd"
    elif ls /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null | head -1 | grep -q .; then
        echo "netplan"
    else
        echo "unknown"
    fi
}

NM=$(detect_nm)
log "Network manager: $NM"

# ---------------------------------------------------------------------------
# NetworkManager (Ubuntu 22.04+, Raspberry Pi OS with NM)
# ---------------------------------------------------------------------------
configure_nm() {
    CONN=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":${IFACE}$" | cut -d: -f1 | head -1)
    [ -z "$CONN" ] && CONN="$IFACE"

    if [ "$MODE" = "dhcp" ]; then
        log "Setting $IFACE to DHCP via NetworkManager ..."
        apply "nmcli con mod \"$CONN\" ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns ''"
        apply "nmcli con up \"$CONN\""
    else
        [ -z "$STATIC_IP" ] && { echo "ERROR: --ip required for static mode"; exit 1; }
        [ -z "$GATEWAY" ]   && { echo "ERROR: --gateway required for static mode"; exit 1; }
        log "Setting $IFACE to static $STATIC_IP via NetworkManager ..."
        apply "nmcli con mod \"$CONN\" ipv4.method manual ipv4.addresses \"$STATIC_IP\" ipv4.gateway \"$GATEWAY\" ipv4.dns \"$DNS\""
        apply "nmcli con up \"$CONN\""
    fi
}

# ---------------------------------------------------------------------------
# dhcpcd (Raspberry Pi OS legacy)
# ---------------------------------------------------------------------------
configure_dhcpcd() {
    CONF="/etc/dhcpcd.conf"

    # Remove existing static block for this interface
    apply "sed -i '/^interface ${IFACE}/,/^$/d' \"$CONF\""

    if [ "$MODE" = "static" ]; then
        [ -z "$STATIC_IP" ] && { echo "ERROR: --ip required for static mode"; exit 1; }
        [ -z "$GATEWAY" ]   && { echo "ERROR: --gateway required for static mode"; exit 1; }
        log "Setting $IFACE to static $STATIC_IP via dhcpcd ..."
        apply "cat >> \"$CONF\" <<EOF

interface ${IFACE}
static ip_address=${STATIC_IP}
static routers=${GATEWAY}
static domain_name_servers=${DNS}
EOF"
    else
        log "Setting $IFACE to DHCP via dhcpcd (removed static block) ..."
    fi
    apply "systemctl restart dhcpcd"
}

# ---------------------------------------------------------------------------
# netplan (Ubuntu Server)
# ---------------------------------------------------------------------------
configure_netplan() {
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null | head -1)
    NETPLAN_BACKUP="${NETPLAN_FILE}.bak.$(date +%Y%m%d%H%M%S)"

    log "Backing up $NETPLAN_FILE → $NETPLAN_BACKUP"
    apply "cp \"$NETPLAN_FILE\" \"$NETPLAN_BACKUP\""

    if [ "$MODE" = "dhcp" ]; then
        log "Setting $IFACE to DHCP via netplan ..."
        apply "cat > \"$NETPLAN_FILE\" <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: true
EOF"
    else
        [ -z "$STATIC_IP" ] && { echo "ERROR: --ip required for static mode"; exit 1; }
        [ -z "$GATEWAY" ]   && { echo "ERROR: --gateway required for static mode"; exit 1; }
        log "Setting $IFACE to static $STATIC_IP via netplan ..."
        apply "cat > \"$NETPLAN_FILE\" <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${STATIC_IP}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF"
    fi
    apply "netplan apply"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case $NM in
    NetworkManager) configure_nm ;;
    dhcpcd)         configure_dhcpcd ;;
    netplan)        configure_netplan ;;
    *)
        echo "ERROR: Unknown network manager. Configure manually."
        echo "  RPi OS:  edit /etc/dhcpcd.conf"
        echo "  Ubuntu:  edit /etc/netplan/*.yaml, run netplan apply"
        exit 1 ;;
esac

echo ""
echo "Network reconfigured to $MODE on $IFACE."
if [ "$MODE" = "dhcp" ]; then
    echo ""
    echo "IMPORTANT after switching to DHCP:"
    echo "  1. Find the new IPs:  hostname -I"
    echo "  2. Run network-config.sh with the new IPs to sync the stack:"
    echo "     sudo bash scripts/network-config.sh --claw-ip <new-claw-ip> --crush-ip <new-crush-ip> --ssh-crush"
    echo "  3. mDNS names still work if on same subnet: claw.local, threadweaver.local, control.local"
fi
