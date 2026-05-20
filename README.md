# PicoCluster Claw

A self-hosted AI agent appliance built on [PicoCluster](https://picocluster.com) hardware. PicoCluster Claw pairs a Raspberry Pi 5 running [OpenClaw](https://github.com/openclaw/openclaw) and [ThreadWeaver](https://github.com/nosqltips/ThreadWeaver) with an NVIDIA Jetson Orin Nano running [Ollama](https://ollama.com) for local LLM inference — giving you a private, always-on AI for under $2/month in electricity.

## Architecture

```
clusterclaw (RPi5 8GB)                    clustercrush (Orin Nano Super 8GB)
├── Portal (nginx :80)                    ├── Ollama :11434  (CUDA)
│   └── CA cert download                 ├── 13 LLM models (GPU-accelerated)
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
sudo bash install-clustercrush.sh 10.1.10.220 granite4.1:8b
```

Installs Ollama with CUDA, pulls 13 default models, sets MAXN power mode, configures GPU model pre-warming on boot, firewall (Ollama only reachable from clusterclaw).

### 3. Install clusterclaw (RPi5)

```bash
# Usage: sudo bash install-clusterclaw.sh [clustercrush-ip] [default-model] [openclaw-token]
sudo bash install-clusterclaw.sh 10.1.10.221 granite4.1:8b picocluster-token
```

Installs Docker containers (ThreadWeaver, OpenClaw, Portal, Caddy), generates local CA + TLS certs, configures Avahi mDNS, Blinkt! LED daemon, firewall.

### 4. Install the CA cert on your devices (one-time)

Open **`http://control.local/ca.crt`** in a browser on each device you'll use to access the cluster. Install the downloaded certificate as a trusted CA:

| Platform | Steps |
|----------|-------|
| **macOS** | Open the `.crt` file → Keychain Access → double-click → set Trust to "Always Trust" |
| **Windows** | Open `.crt` → Install Certificate → Local Machine → Trusted Root CAs |
| **iOS** | Tap the download link in Safari → Settings → General → VPN & Device Management → install profile → trust in Certificate Trust Settings |
| **Android** | Settings → Security → Install certificate → CA certificate |
| **Linux** | `sudo cp picocluster-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |

The portal page at `http://control.local` has full platform-specific instructions.

### 5. Access your AI

| Interface | URL | Notes |
|-----------|-----|-------|
| **PicoCluster Claw Portal** | `http://control.local` | Status, setup guide, CA cert download |
| **OpenClaw** | `https://claw.local` | Agent dashboard (token: `picocluster-token`) |
| **ThreadWeaver** | `https://threadweaver.local` | Chat UI |
| **Ollama API** | `http://clustercrush:11434/v1` | OpenAI-compatible endpoint |

`claw.local` and `threadweaver.local` are HTTPS and require the CA cert installed (step 4). `control.local` is always HTTP — use it for first-time setup and CA cert download.

**SSH tunnel (fallback — no CA cert needed):**
```bash
ssh -L 5174:localhost:5174 -L 18790:localhost:18790 picocluster@clusterclaw
# Then: https://localhost:18790 (OpenClaw)  https://localhost:5174 (ThreadWeaver)
```

## Solo Installs

Don't have the hardware yet? PicoCluster Claw runs as a single-machine stack on Mac, Linux, and Windows. Ollama runs natively (Metal GPU on Mac, NVIDIA/AMD/CPU on Linux and Windows); Docker containers provide ThreadWeaver, OpenClaw, and the Portal.

### Mac (Apple Silicon)

```bash
bash scripts/setup/install-mac.sh [model]
# Default model: granite4.1:8b
```

Requires Docker Desktop and Ollama (auto-installed via Homebrew if missing).

| URL | Service |
|-----|---------|
| `http://localhost:5173` | ThreadWeaver |
| `http://localhost:18789` | OpenClaw |
| `http://localhost/` | Portal |

### Linux (Ubuntu 22.04+ / Debian 12+)

```bash
bash scripts/setup/install-linux.sh [model]
```

Installs Docker via `get.docker.com` and Ollama via the official install script. NVIDIA and AMD GPUs are auto-detected.

### Windows 10/11

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\scripts\setup\install-windows.ps1 [model]
```

Requires winget (included in Windows 10/11). Docker Desktop and Ollama are installed automatically. If Docker Desktop was just installed, the script will prompt you to open it and complete first-time setup, then re-run.

### Updating (all solo platforms)

```bash
bash scripts/setup/update-mac.sh        # Mac
bash scripts/setup/update-linux.sh      # Linux
.\scripts\setup\update-windows.ps1      # Windows (PowerShell)
```

## Networking

The cluster uses **static IPs** and **mDNS** (`.local` hostnames) for LAN access. Three access options are supported:

### Option A — LAN (default)

`claw.local`, `threadweaver.local`, and `control.local` resolve via mDNS on the same subnet. The cluster publishes them as CNAME records pointing to `clusterclaw.local`, so they work without any client configuration:

| Platform | Status |
|---|---|
| macOS | Works natively (Bonjour follows CNAME) |
| Linux | Works natively (avahi + libnss-mdns or systemd-resolved) |
| Windows 10/11 | Works natively; Bonjour for Windows (from iTunes/Apple) guarantees it |

**Fallback:** if mDNS is blocked on your network, add to your system hosts file:
```
10.1.10.220  clusterclaw clusterclaw.local claw.local threadweaver.local control.local
```
- macOS/Linux: `/etc/hosts`
- Windows: `C:\Windows\System32\drivers\etc\hosts`

HTTPS is secured with a pre-generated local CA — install it once per device (step 4) for no browser warnings.

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

Models run on the Jetson Orin Nano Super (8GB unified memory) via Ollama. `granite4.1:8b` is the default — pre-warmed into GPU memory on every boot for instant first response.

| Model | Size | OpenClaw | ThreadWeaver | Notes |
|-------|-----:|:--------:|:------------:|-------|
| **granite4.1:8b** | 5.0 GB | ✓ default | ✓ | **Best agent scores (10/10)** — pre-warmed on boot |
| qwen3.5:4b | 2.4 GB | ✓ | ✓ | Strong reasoning, 8/10 agent score |
| nemotron-3-nano:4b | 2.5 GB | ✓ | ✓ | NVIDIA-optimized for Jetson, 6/10 agent score |
| qwen3.5:9b | 5.8 GB | — | ✓ | Larger Qwen, ThreadWeaver only |
| llama3.1:8b | 4.9 GB | — | ✓ | Meta general-purpose |
| llama3.2:3b | 2.0 GB | — | ✓ | Fast, lightweight |
| deepseek-r1:7b | 4.7 GB | — | ✓ | Chain-of-thought reasoning |
| qwen3.5:14b | 9.0 GB | — | ✓ | Large tier — swap-heavy on 8GB |
| deepseek-r1:14b | 9.0 GB | — | ✓ | Large tier — swap-heavy on 8GB |
| phi-4:14b | 9.1 GB | — | ✓ | Large tier — swap-heavy on 8GB |

> **OpenClaw vs ThreadWeaver:** OpenClaw exposes only the three validated agent models in its picker. ThreadWeaver shows all Ollama models. Add any model with `ollama pull <model>` — it appears in ThreadWeaver immediately.

> **Tool calling:** All OpenClaw models support tool calling. ThreadWeaver uses MCP tools independently of the model selected.

**GPU pre-warming:** `granite4.1:8b` loads into GPU memory on every boot. When you change models, ThreadWeaver pre-warms the new model in the background so the first message is instant.

```bash
# Manage models on clustercrush:
ollama list
ollama pull <model>
ollama rm <model>
```

## AI Context

OpenClaw uses **model-aware context** to get the best results from small local models while preserving full capability for cloud models.

### Local models (granite, qwen, nemotron)

Receive a lean, focused context (~9,250 chars) optimized for 4-8B parameter reasoning limits:

| Tool category | Available |
|---|---|
| Workspace: `read` / `write` / `edit` | ✓ |
| Shell: `exec` | ✓ |
| Scheduling: `cron` | ✓ |
| Web: `web_search` / `web_fetch` | ✓ |
| Browser automation, TTS, image/video generation | — (local only) |

The four remote-node file-transfer tools (`file_fetch`, `dir_list`, `dir_fetch`, `file_write`) are stripped from the schema — they require a paired remote node that isn't configured, and their presence was confusing smaller models.

### Cloud models (Claude, GPT, Gemini, etc.)

Adding a cloud provider API key in the OpenClaw settings page **automatically unlocks the full tool set** — no config changes needed. Cloud models receive ~6,700 chars of tool schemas covering everything: browser automation, TTS, image/video/music generation, cron scheduling, and all workspace tools.

This is handled by OpenClaw's native `tools.byProvider` policy: the `local` provider gets the lean profile; all other providers (anthropic, openai, gemini, etc.) get the unrestricted profile.

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
| Portal (nginx) | clusterclaw | 80 | `http://control.local` |
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
├── docker-compose.yml              # Base services (ThreadWeaver, OpenClaw, Portal, Caddy)
├── docker-compose.mac.yml          # Mac Solo overlay (Ollama via Metal GPU)
├── docker-compose.linux.yml        # Linux Solo overlay (Ollama native, GPU or CPU)
├── docker-compose.windows.yml      # Windows Solo overlay (Ollama native, GPU or CPU)
├── .env                            # CRUSH_IP, DEFAULT_MODEL, OPENCLAW_TOKEN
├── portal/                         # Landing pages (nginx :80) + nginx config
│   ├── index.html                  # Cluster edition portal
│   ├── index-mac.html              # Mac Solo portal
│   ├── index-linux.html            # Linux Solo portal
│   └── index-windows.html          # Windows Solo portal
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
        ├── install-mac.sh          # Mac Solo installer
        ├── install-linux.sh        # Linux Solo installer
        ├── install-windows.ps1     # Windows Solo installer (PowerShell)
        ├── update-clusterclaw.sh   # Update cluster (RPi5)
        ├── update-mac.sh           # Update Mac Solo
        ├── update-linux.sh         # Update Linux Solo
        ├── update-windows.ps1      # Update Windows Solo (PowerShell)
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
