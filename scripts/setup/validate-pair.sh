#!/bin/bash
# validate-pair.sh — End-to-end health checks for a PicoCluster Claw pair
# Run from either node or your local machine.
#
# Usage: bash validate-pair.sh [claw-ip] [crush-ip]
set -euo pipefail

CLAW_IP="${1:-${CLAW_IP:-10.1.10.220}}"
CRUSH_IP="${2:-${CRUSH_IP:-10.1.10.221}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass=0; fail=0; warn=0

check() {
  local label="$1" cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}  $label"
    ((pass++))
  else
    echo -e "  ${RED}FAIL${NC}  $label"
    ((fail++))
  fi
}

warn_check() {
  local label="$1" cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}  $label"
    ((pass++))
  else
    echo -e "  ${YELLOW}WARN${NC}  $label"
    ((warn++))
  fi
}

section() { echo ""; echo -e "${BLUE}--- $* ---${NC}"; }

echo "=== PicoCluster Claw Pair Validation ==="
echo "  clusterclaw (claw): $CLAW_IP"
echo "  clustercrush (crush): $CRUSH_IP"
echo ""

# ── Network ──────────────────────────────────────────────────────────────────
section "Network"
check  "Ping clusterclaw ($CLAW_IP)"  "ping -c 1 -W 2 $CLAW_IP"
check  "Ping clustercrush ($CRUSH_IP)" "ping -c 1 -W 2 $CRUSH_IP"
check  "SSH clusterclaw"  "ssh -o ConnectTimeout=5 -o BatchMode=yes picocluster@$CLAW_IP true 2>/dev/null || timeout 5 bash -c 'echo | nc -w 2 $CLAW_IP 22'"
check  "SSH clustercrush" "ssh -o ConnectTimeout=5 -o BatchMode=yes picocluster@$CRUSH_IP true 2>/dev/null || timeout 5 bash -c 'echo | nc -w 2 $CRUSH_IP 22'"

# ── mDNS ─────────────────────────────────────────────────────────────────────
section "mDNS (requires Avahi on client)"
warn_check "claw.local resolves"         "getent hosts claw.local || ping -c 1 -W 2 claw.local"
warn_check "threadweaver.local resolves" "getent hosts threadweaver.local || ping -c 1 -W 2 threadweaver.local"
warn_check "control.local resolves"      "getent hosts control.local || ping -c 1 -W 2 control.local"

# ── TLS / CA cert ────────────────────────────────────────────────────────────
section "TLS"
check  "CA cert downloadable (HTTP)"         "curl -sf --max-time 5 http://$CLAW_IP/ca.crt | openssl x509 -noout"
warn_check "https://claw.local reachable"    "curl -sf --max-time 5 --cacert /opt/picocluster/pki/ca.crt https://claw.local/__openclaw__/health"
warn_check "https://threadweaver.local reachable" "curl -sf --max-time 5 --cacert /opt/picocluster/pki/ca.crt https://threadweaver.local/api/settings"

# ── clustercrush (Orin) ───────────────────────────────────────────────────────
section "clustercrush / crush (Orin Nano)"
check  "Ollama health"            "curl -sf --max-time 5 http://$CRUSH_IP:11434/api/tags | grep -q models"
check  "Ollama has models loaded" "curl -sf --max-time 5 http://$CRUSH_IP:11434/api/tags | grep -q name"
warn_check "GPU accessible"       "ssh -o ConnectTimeout=5 picocluster@$CRUSH_IP 'nvidia-smi' 2>/dev/null"
warn_check "Ollama service enabled" "ssh -o ConnectTimeout=5 picocluster@$CRUSH_IP 'systemctl is-enabled ollama' 2>/dev/null"

echo -n "  "
INFERENCE=$(curl -sf --max-time 30 "http://$CRUSH_IP:11434/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}' 2>/dev/null || true)
if echo "$INFERENCE" | grep -q '"content"'; then
  echo -e "${GREEN}PASS${NC}  Inference round-trip"
  ((pass++))
else
  echo -e "${RED}FAIL${NC}  Inference round-trip"
  ((fail++))
fi

# ── clusterclaw (RPi5) ────────────────────────────────────────────────────────
section "clusterclaw / claw (RPi5)"
check  "Portal (HTTP)"            "curl -sf --max-time 5 http://$CLAW_IP/ | grep -qi picocluster"
check  "OpenClaw health"          "curl -sf --max-time 5 http://$CLAW_IP:18789/__openclaw__/health"
check  "ThreadWeaver backend"     "curl -sf --max-time 5 http://$CLAW_IP:8000/api/settings | grep -q provider"
check  "ThreadWeaver frontend"    "curl -sf --max-time 5 http://$CLAW_IP:5173/ | grep -qi html"
warn_check "Avahi running"        "ssh -o ConnectTimeout=5 picocluster@$CLAW_IP 'systemctl is-active avahi-daemon' 2>/dev/null"
warn_check "Blinkt! LEDs running" "ssh -o ConnectTimeout=5 picocluster@$CLAW_IP 'systemctl is-active clusterclaw-leds' 2>/dev/null"
warn_check "UFW active"           "ssh -o ConnectTimeout=5 picocluster@$CLAW_IP 'sudo ufw status | grep -q active' 2>/dev/null"

# ── Cross-node ────────────────────────────────────────────────────────────────
section "Cross-node"
check "clusterclaw → Ollama inference" \
  "curl -sf --max-time 10 http://$CLAW_IP:8000/api/models/local | grep -q models"

# ── Model info ────────────────────────────────────────────────────────────────
section "Model info"
ACTIVE_MODELS=$(curl -sf --max-time 5 "http://$CRUSH_IP:11434/api/tags" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(m['name'] for m in d.get('models',[])) or 'none')" \
  2>/dev/null || echo "unknown")
echo "  Loaded models: $ACTIVE_MODELS"
GPU_MEM=$(ssh -o ConnectTimeout=5 picocluster@$CRUSH_IP \
  'nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader' 2>/dev/null || echo "unknown")
echo "  GPU memory:    $GPU_MEM"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
total=$((pass + fail + warn))
echo -e "  ${GREEN}PASS: $pass${NC}  ${RED}FAIL: $fail${NC}  ${YELLOW}WARN: $warn${NC}  (total: $total)"
if [[ $fail -eq 0 ]]; then
  echo -e "  ${GREEN}Cluster is operational.${NC}"
else
  echo -e "  ${RED}$fail check(s) failed — review above.${NC}"
fi
echo "============================================"

exit $fail
