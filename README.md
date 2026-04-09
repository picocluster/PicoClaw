# PicoClaw

A self-hosted AI agent appliance built on [PicoCluster](https://picocluster.com) hardware. PicoClaw pairs a Raspberry Pi 5 running [OpenClaw](https://github.com/openclaw/openclaw) and [ThreadWeaver](https://github.com/nosqltips/ThreadWeaver) with an NVIDIA Jetson Orin Nano running [Ollama](https://ollama.com) for local LLM inference — giving you a private, always-on AI for under $2/month in electricity.

## Architecture

```
picoclaw (RPi5 8GB)                picocrush (Orin Nano Super 8GB)
├── Portal :80                     ├── Ollama :11434
├── ThreadWeaver :5173             ├── 9 LLM models (GPU-accelerated)
├── OpenClaw Gateway :18789        ├── Vision, Code, Reasoning models
├── Caddy HTTPS proxy :18790       ├── OpenAI-compatible API
├── Blinkt! LED status             └── CUDA / cuDNN / TensorRT
└── Docker containers                      │
        │                                  │
        └──── HTTP (port 11434) ───────────┘
```

## Hardware

| Component | Role | Power |
|-----------|------|------:|
| Raspberry Pi 5 (8GB) | Web UIs, agent orchestrator | ~3-7.5W |
| NVIDIA Jetson Orin Nano Super (8GB) | LLM inference (Ollama) | ~6-20W |
| MicroSD 128GB (both nodes) | Boot + OS | |
| NVMe SSD 256GB+ (Orin) | Model storage | |
| PicoCluster case + 50W PSU | Enclosure + power | |
| Pimoroni Blinkt! (RPi5) | LED status indicator | |

**Total power:** ~14W idle, ~20W typical, ~35W peak

## Quick Start

### 1. Flash golden images

Flash the PicoClaw images to both nodes using `dd` or your preferred imaging tool.

### 2. Install picocrush (Orin Nano)

```bash
sudo bash install-picocrush.sh
```

Installs Ollama with CUDA, pulls 9 default models, configures firewall and power mode.

### 3. Install picoclaw (RPi5)

```bash
sudo bash install-picoclaw.sh
```

Installs Docker containers (ThreadWeaver, OpenClaw, Portal, Caddy), Blinkt! LED daemon, configures firewall.

### 4. Access your AI

Open **http://picoclaw** in your browser for the PicoClaw portal with links to all services.

| Interface | URL | Notes |
|-----------|-----|-------|
| **PicoClaw Portal** | `http://picoclaw` | Landing page with status and docs |
| **ThreadWeaver** | `http://picoclaw:5173` | Chat UI — works directly over HTTP |
| **OpenClaw Dashboard** | `https://localhost:18790` | Requires SSH tunnel (see below) |
| **OpenClaw TUI** | `ssh picocluster@picoclaw` then `openclaw tui` | Terminal chat |
| **Ollama API** | `http://picocrush:11434/v1` | OpenAI-compatible endpoint |

**SSH tunnel for OpenClaw Dashboard:**
```bash
ssh -L 18790:localhost:18790 picocluster@picoclaw
```
Then open `https://localhost:18790` (token: `picocluster-token`)

See [docs/access-guide.md](docs/access-guide.md) for all access methods including Tailscale, Telegram, and mobile.

## Models

9 models installed by default (~27GB on NVMe). Ollama manages loading/unloading automatically.

| Model | Size | Type |
|-------|-----:|------|
| llama3.2:3b | 2.0 GB | General (primary) |
| llama3.1:8b | 4.9 GB | General (quality) |
| gemma3:4b | 3.3 GB | General (multilingual) |
| phi3.5:3.8b | 2.2 GB | Reasoning |
| deepseek-r1:7b | 4.7 GB | Reasoning (chain-of-thought) |
| qwen2.5:3b | 1.9 GB | Code / structured output |
| starcoder2:3b | 1.7 GB | Code generation |
| llava:7b | 4.7 GB | Vision (image understanding) |
| moondream:1.8b | 1.7 GB | Vision (lightweight) |

```bash
# Add more models on picocrush:
ollama pull <model>
ollama list
```

## Management

| Task | Command |
|------|---------|
| Update ThreadWeaver | `sudo bash /opt/picoclcaw/scripts/setup/update-threadweaver.sh` |
| Update all containers | `sudo bash /opt/picoclcaw/scripts/setup/update-picoclaw.sh` |
| Update Ollama + models | `sudo bash /opt/picoclcaw/scripts/setup/update-picocrush.sh` |
| Container status | `cd /opt/picoclcaw && sudo docker compose ps` |
| View logs | `cd /opt/picoclcaw && sudo docker compose logs -f` |
| Restart services | `cd /opt/picoclcaw && sudo docker compose restart` |
| Add a model | `ssh picocrush` then `ollama pull <model>` |
| Validate cluster | `bash /opt/picoclcaw/scripts/setup/validate-pair.sh` |

## Blinkt! LED Status

The Pimoroni Blinkt! on picoclaw provides visual feedback:

- **Scanning eye**: Idle — color-shifting Larson scanner with blink and look-around behaviors
- **Green/cyan chase**: LLM inference active
- **Amber pulse**: Service degraded
- **Red pulse**: Services down
- **Boot sequence**: Rainbow → blue sweep → amber progress → green ready

## Repository Structure

```
PicoClaw/
├── docker-compose.yml              # All services (ThreadWeaver, OpenClaw, Portal, Caddy)
├── portal/                         # PicoClaw landing page (nginx on port 80)
├── openclaw/                       # OpenClaw Dockerfile + config
├── threadweaver/                   # ThreadWeaver Dockerfile + patches
├── leds/                           # Blinkt! LED driver and status daemon
├── scripts/
│   ├── setup/                      # Install, update, configure, validate scripts
│   ├── imaging/                    # Image capture, shrink, resize, NVMe migration
│   └── testing/                    # Stress tests and benchmarking
└── docs/                           # Documentation
    ├── access-guide.md             # All access methods and troubleshooting
    ├── benchmark-report.md         # Power, thermal, performance data
    ├── storage-options.md          # Drive sizing recommendations
    └── roadmap.md                  # Project roadmap
```

## Energy Cost

| Scenario | Power | Monthly | Annual |
|----------|------:|--------:|-------:|
| Idle (waiting for tasks) | 14W | $1.61 | $19.62 |
| Typical agent workload | 20W | $2.30 | $28.03 |
| Realistic blend (90% idle) | 15W | $1.73 | $21.02 |

*Your own private AI for under $2/month.*

## Security

- All services run on your local network — no cloud dependencies
- OpenClaw in Docker container (isolated)
- OpenClaw dashboard requires HTTPS + token authentication
- Ollama restricted to picoclaw IP via firewall
- SSH hardened (no root login)
- UFW firewall on both nodes
- fail2ban on SSH
- Automatic security updates

## Services Overview

| Service | Node | Port | Container |
|---------|------|------|-----------|
| PicoClaw Portal | picoclaw | 80 | nginx |
| ThreadWeaver UI | picoclaw | 5173 | threadweaver |
| ThreadWeaver API | picoclaw | 8000 | threadweaver |
| OpenClaw Gateway | picoclaw | 18789 | openclaw |
| OpenClaw HTTPS | picoclaw | 18790 | caddy |
| Blinkt! LEDs | picoclaw | GPIO | native |
| Ollama | picocrush | 11434 | native |

## Default Credentials

| Service | Credential | Value |
|---------|-----------|-------|
| SSH (both nodes) | User / Password | `picocluster` / `picocluster` |
| OpenClaw | Gateway Token | `picocluster-token` |
| Ollama | Auth | None (firewall-restricted) |

> **Note:** Hostnames, IPs, and credentials shown are defaults. If you changed them via `configure-pair.sh`, substitute your values.

## License

Apache 2.0

## Links

- [PicoCluster](https://picocluster.com)
- [ThreadWeaver](https://github.com/nosqltips/ThreadWeaver)
- [OpenClaw](https://github.com/openclaw/openclaw)
- [Ollama](https://ollama.com)
- [llama.cpp](https://github.com/ggerganov/llama.cpp)
