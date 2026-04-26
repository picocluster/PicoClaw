# PicoCluster Claw

A self-hosted AI agent appliance built on [PicoCluster](https://picocluster.com) hardware. PicoCluster Claw pairs a Raspberry Pi 5 running [OpenClaw](https://github.com/openclaw/openclaw) and [ThreadWeaver](https://github.com/nosqltips/ThreadWeaver) with an NVIDIA Jetson Orin Nano running [Ollama](https://ollama.com) for local LLM inference — giving you a private, always-on AI for under $2/month in electricity.

## Architecture

```
clusterclaw (RPi5 8GB)                    clustercrush (Orin Nano Super 8GB)
├── Portal (nginx :80)                    ├── Ollama :11434  (CUDA)
│   └── CA cert download                 ├── 9 LLM models (GPU-accelerated)
├── Caddy HTTPS proxy (:443)             ├── OpenAI-compatible API (/v1)
│   ├── claw.local → OpenClaw           └── CUDA / cuDNN / TensorRT
│   └── threadweaver.local → TW
├── ThreadWeaver (chat UI + API)                      │
├── OpenClaw (agent gateway)              ←── Ollama HTTP :11434 ──┘
├── Blinkt! LED status
└── Docker containers
```

**Access:**
- LAN: `https://claw.local` · `https://threadweaver.local` (after one-time CA cert install)
- Remote: Tailscale (optional)
- Fallback: SSH tunnel

## Hardware

| Component | Role | Power |
|-----------|------|------:|
| Raspberry Pi 5 (8GB) | Web UIs, agent orchestrator | ~3–7.5W |
| NVIDIA Jetson Orin Nano Super (8GB) | LLM inference (Ollama + CUDA) | ~6–20W |
| MicroSD 128GB (both nodes) | Boot + OS | — |
| NVMe SSD 256GB+ (Orin, optional) | Model storage | — |
| PicoCluster case + 50W PSU | Enclosure + power | — |
| Pimoroni Blinkt! (RPi5) | LED status indicator | — |

**Total power:** ~14W idle · ~20W typical · ~35W peak

## Quick Start

### 1. Flash golden images

Flash the PicoCluster Claw images to both nodes using `dd` or your preferred imaging tool.

### 2. Install clustercrush (Orin Nano)

```bash
# Usage: sudo bash install-clustercrush.sh [clusterclaw-ip] [default-model]
sudo bash install-clustercrush.sh 10.1.10.220 llama3.1:8b
```

Installs Ollama with CUDA, pulls 9 default models, sets MAXN power mode, configures GPU model pre-warming on boot, firewall (Ollama only reachable from clusterclaw).

### 3. Install clusterclaw (RPi5)

```bash
# Usage: sudo bash install-clusterclaw.sh [clustercrush-ip] [default-model] [openclaw-token]
sudo bash install-clusterclaw.sh 10.1.10.221 llama3.1:8b picocluster-token
```

Installs Docker containers (ThreadWeaver, OpenClaw, Portal, Caddy), generates local CA + TLS certs, configures Avahi mDNS, Blinkt! LED daemon, firewall.

### 4. Install the CA cert on your devices (one-time)

Open **`http://clusterclaw.local/ca.crt`** in a browser on each device you'll use to access the cluster. Install the downloaded certificate as a trusted CA:

| Platform | Steps |
|----------|-------|
| **macOS** | Open the `.crt` file → Keychain Access → double-click → set Trust to "Always Trust" |
| **Windows** | Open `.crt` → Install Certificate → Local Machine → Trusted Root CAs |
| **iOS** | Tap the download link in Safari → Settings → General → VPN & Device Management → install profile → trust in Certificate Trust Settings |
| **Android** | Settings → Security → Install certificate → CA certificate |
| **Linux** | `sudo cp picocluster-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |

The portal page at `http://clusterclaw.local` has full platform-specific instructions.

### 5. Access your AI

| Interface | URL | Notes |
|-----------|-----|-------|
| **PicoCluster Claw Portal** | `http://clusterclaw.local` | Status, setup guide, management |
| **OpenClaw** | `https://claw.local` | Agent dashboard (token: `picocluster-token`) |
| **ThreadWeaver** | `https://threadweaver.local` | Chat UI |
| **Ollama API** | `http://clustercrush:11434/v1` | OpenAI-compatible endpoint |

Both `claw.local` and `threadweaver.local` require the CA cert installed (step 4) — no browser warnings after that. The portal is always available over HTTP for first-time setup.

**SSH tunnel (fallback — no CA cert needed):**
```bash
ssh -L 5174:localhost:5174 -L 18790:localhost:18790 picocluster@clusterclaw
# Then: https://localhost:18790 (OpenClaw)  https://localhost:5174 (ThreadWeaver)
```

## Networking

The cluster uses **static IPs** and **mDNS** (`.local` hostnames) for LAN access. Three access options are supported:

### Option A — LAN (default)

`claw.local` and `threadweaver.local` resolve via Avahi/mDNS on the same subnet. HTTPS is secured with a pre-generated local CA (no browser warnings after one CA cert install per device).

Works on most home/office networks. **macOS note:** if `.local` names don't resolve (Bonjour sometimes ignores third-party mDNS aliases), add these lines to your Mac's `/etc/hosts`:

```
10.1.10.220  clusterclaw.local claw.local threadweaver.local
10.1.10.221  clustercrush.local
```

If mDNS is blocked entirely, use the SSH tunnel fallback below.

### Option B — Reconfigure for a different network

If the cluster was pre-configured for `10.1.10.x` and you need it on a different subnet:

```bash
# Update all config files + Docker + Avahi in one command
sudo bash /opt/clusterclaw/scripts/network-config.sh \
  --claw-ip 192.168.1.50 \
  --crush-ip 192.168.1.51 \
  --ssh-crush   # also syncs /etc/hosts + firewall on clustercrush via SSH

# Switch interface from static IP to DHCP (if preferred)
sudo bash /opt/clusterclaw/scripts/set-network.sh dhcp
# Then run network-config.sh with the new DHCP-assigned IPs
```

`network-config.sh` updates: `.env`, `/etc/hosts` on clusterclaw, `/etc/avahi/hosts` (both mDNS aliases), Docker services. With `--ssh-crush` it also syncs clustercrush.

`set-network.sh` handles NetworkManager, dhcpcd, and netplan automatically.

### Option C — Tailscale (remote/cross-network access)

For access outside your home network, across subnets, or through corporate firewalls:

```bash
# Interactive setup — follow the browser URL to authenticate
sudo bash /opt/clusterclaw/scripts/setup-tailscale.sh

# Automated (pre-ship provisioning) — auth key from tailscale.com/admin
sudo bash /opt/clusterclaw/scripts/setup-tailscale.sh --authkey tskey-auth-xxx

# Install Tailscale on both nodes in one pass
sudo bash /opt/clusterclaw/scripts/setup-tailscale.sh --authkey tskey-auth-xxx --ssh-crush
```

After connecting, install [Tailscale](https://tailscale.com/download) on your devices. Access the cluster via its Tailscale IP or MagicDNS name from anywhere.

## Models

9 models installed by default (~27GB on NVMe). `llama3.1:8b` is the default — pre-warmed into GPU memory on every boot for instant first response. Ollama manages loading/unloading automatically.

| Model | Size | Type | Notes |
|-------|-----:|------|-------|
| **llama3.1:8b** | 4.9 GB | General | **Default** — pre-warmed on boot, tool-calling |
| llama3.2:3b | 2.0 GB | General | Fast, tool-calling |
| gemma3:4b | 3.3 GB | General | Multilingual |
| phi3.5:3.8b | 2.2 GB | Reasoning | Tool-calling |
| deepseek-r1:7b | 4.7 GB | Reasoning | Chain-of-thought |
| qwen2.5:3b | 1.9 GB | Code | Structured output, tool-calling |
| starcoder2:3b | 1.7 GB | Code | Code generation |
| llava:7b | 4.7 GB | Vision | Image understanding |
| moondream:1.8b | 1.7 GB | Vision | Lightweight |

> **Tool calling:** ThreadWeaver MCP tools require a tool-capable model. Gemma3 and vision models fall back to chat-only. Recommended: `llama3.1:8b`.

**GPU pre-warming:** When you change the active model in ThreadWeaver, a background request pre-loads it into GPU memory so the next message is instant.

```bash
# Manage models on clustercrush:
ollama list
ollama pull <model>
ollama rm <model>
```

## Management

| Task | Command (on clusterclaw) |
|------|--------------------------|
| Container status | `cd /opt/clusterclaw && docker compose ps` |
| View logs | `cd /opt/clusterclaw && docker compose logs -f` |
| Restart services | `cd /opt/clusterclaw && docker compose restart` |
| Update containers | `cd /opt/clusterclaw && git pull && docker compose build --pull && docker compose up -d` |
| Reconfigure network | `sudo bash /opt/clusterclaw/scripts/network-config.sh --claw-ip <ip> --crush-ip <ip>` |
| Switch to DHCP | `sudo bash /opt/clusterclaw/scripts/set-network.sh dhcp` |
| Setup Tailscale | `sudo bash /opt/clusterclaw/scripts/setup-tailscale.sh` |
| Add a model | `ssh clustercrush` then `ollama pull <model>` |
| Validate cluster | `bash /opt/clusterclaw/scripts/setup/validate-pair.sh` |

**User files** written by OpenClaw and ThreadWeaver are at `/home/picocluster/claw-files/`:
- `openclaw/` — agent downloads, screenshots, generated files
- `threadweaver/` — sandbox workspace files

## Blinkt! LED Status

The Pimoroni Blinkt! on clusterclaw provides visual feedback:

| Pattern | Meaning |
|---------|---------|
| Scanning eye (color-shifting) | Idle |
| Green/cyan chase | LLM inference active |
| Purple pulse | OpenClaw agent thinking |
| Amber pulse | Service degraded |
| Red pulse | Services down |
| Boot sequence | Rainbow → blue sweep → amber → green |

LED controls are available in the portal, via MCP tools from ThreadWeaver, and via HTTP API on port 7777.

## MCP Servers

5 MCP servers auto-connect to ThreadWeaver on startup, giving local LLMs **28 tools** — including physical LED control, system monitoring, time awareness, sandboxed file operations, and Ollama management.

> **User:** "Make the LEDs purple and tell me the GPU memory usage on clustercrush"
> **LLM:** *calls `leds__set_led_color` and `clustercrush__get_gpu_memory`* → Blinkt! turns purple, reports VRAM stats

| Server | Tools | Purpose |
|--------|------:|---------|
| **leds** | 5 | Control Blinkt! LEDs (color, progress, pulse, clear) |
| **system** | 6 | clusterclaw stats (CPU, memory, disk, temp, uptime, network) |
| **clustercrush** | 4 | Ollama management (list models, active models, GPU memory, pull) |
| **time** | 4 | Current time/date, countdowns, duration formatting |
| **files** | 5 | Sandboxed file ops in `/workspace` (read, write, list, delete) |

See [docs/mcp-tools.md](docs/mcp-tools.md) for the full tool reference and HTTP API.

## Services Overview

| Service | Node | Port | Access |
|---------|------|------|--------|
| Portal (nginx) | clusterclaw | 80 | `http://clusterclaw.local` |
| Caddy HTTPS proxy | clusterclaw | 443 | host network |
| OpenClaw | clusterclaw | 18789 (localhost) | `https://claw.local` via Caddy |
| ThreadWeaver UI | clusterclaw | 5173 (localhost) | `https://threadweaver.local` via Caddy |
| ThreadWeaver API | clusterclaw | 8000 (localhost) | internal |
| LED API | clusterclaw | 7777 | LAN |
| Shutdown API | clusterclaw | 8888 | LAN |
| Ollama | clustercrush | 11434 | clusterclaw only (firewall) |

Raw ports (18789, 5173, 8000) are localhost-only; all external access goes through Caddy on 443.

## Repository Structure

```
PicoCluster-Claw/
├── docker-compose.yml              # All services (ThreadWeaver, OpenClaw, Portal, Caddy)
├── .env                            # CRUSH_IP, DEFAULT_MODEL, OPENCLAW_TOKEN
├── portal/                         # Landing page (nginx :80) + nginx config
├── openclaw/                       # OpenClaw Dockerfile + Caddyfile
├── threadweaver/                   # ThreadWeaver Dockerfile + patches
├── leds/                           # Blinkt! driver, status daemon, MCP server
├── mcp/                            # MCP servers (system, clustercrush, time, files)
└── scripts/
    ├── generate-pki.sh             # Generate local CA + TLS certs for claw.local / threadweaver.local
    ├── network-config.sh           # Reconfigure network IPs across the full stack
    ├── set-network.sh              # Switch interface between static IP and DHCP
    ├── setup-tailscale.sh          # Install + configure Tailscale (optional remote access)
    └── setup/
        ├── install-clusterclaw.sh  # Full RPi5 installer
        ├── install-clustercrush.sh # Full Orin installer
        └── validate-pair.sh        # Verify cluster is healthy
```

## Security

- All services on your local network — no cloud dependencies, no telemetry
- HTTPS everywhere via local CA (no browser warnings after one-time cert install)
- Raw service ports (OpenClaw, ThreadWeaver) bound to `127.0.0.1` only — external access through Caddy
- OpenClaw requires token authentication
- Ollama firewalled to clusterclaw IP only
- SSH: no root login, fail2ban on both nodes
- UFW firewall on both nodes

## Default Credentials

| Service | Credential | Value |
|---------|-----------|-------|
| SSH (both nodes) | User / Password | `picocluster` / `picocluster` |
| OpenClaw | Gateway Token | `picocluster-token` |
| Ollama | Auth | None (firewall-restricted to clusterclaw) |

> Change the SSH password and OpenClaw token after first login.

## Energy Cost

| Scenario | Power | Monthly | Annual |
|----------|------:|--------:|-------:|
| Idle | 14W | $1.61 | $19.62 |
| Typical workload | 20W | $2.30 | $28.03 |
| Realistic blend (90% idle) | 15W | $1.73 | $21.02 |

*Your own private AI for under $2/month.*

## Links

- [PicoCluster](https://picocluster.com)
- [ThreadWeaver](https://github.com/nosqltips/ThreadWeaver)
- [OpenClaw](https://github.com/openclaw/openclaw)
- [Ollama](https://ollama.com)
- [Tailscale](https://tailscale.com)

## License

Apache 2.0
