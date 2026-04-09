# PicoClaw Appliance — Roadmap

## Architecture
- **picoclaw — RPi5 (8GB)** — Portal, ThreadWeaver, OpenClaw, Blinkt! LEDs (Docker)
- **picocrush — Orin Nano Super (8GB)** — Ollama with 9 LLM models, GPU-accelerated
- Shared case, shared power, shared network, 50W PSU

## Phase 1: Benchmarking (COMPLETE ✅)
- [x] Orin Nano power draw characterization across 15W / 25W / MAXN
- [x] LLM inference benchmarks (TinyLlama 1.1B, Phi-3 3.8B, Llama 3.2 3B)
- [x] Thermal analysis — no throttling detected
- [x] I/O stress testing (NVMe + network) — true headless max: 20.4W at MAXN
- [x] PDU validation — all 3 ports tested at 12V, held 1.81A sustained
- [x] In-case thermal testing — case fan reduces temps 5-10°C vs open air
- [x] Cluster power draw: 14W idle, 20W typical, 35W peak

## Phase 2: Tooling & Infrastructure (COMPLETE ✅)
- [x] Orin Nano imaging: jetson-shrink.sh (dd capture → shrink → gzip)
- [x] Orin Nano resize: resize_ubuntu.sh (expand rootfs after flash)
- [x] RPi5 resize: resize_raspbian.sh (expand rootfs after flash)
- [x] Orin Nano NVMe boot: sd-to-nvme.sh (migrate SD → NVMe)
- [x] Node configuration: configure-pair.sh (IPs, hostnames, config files)
- [x] Ansible playbook structure (site.yml, validate.yml, roles)
- [x] Storage recommendations documented (128GB microSD + 256GB NVMe)

## Phase 3: Golden Image Creation (COMPLETE ✅)
- [x] RPi5: build-rpi5-image.sh — strip Raspbian Desktop to headless
- [x] Orin Nano: build-orin-image.sh — strip JetPack Desktop, preserve CUDA
- [x] SSH hardening, UFW firewall, fail2ban on both nodes
- [x] Golden images captured, shrunk, archived
- [x] L4T packages held to prevent apt upgrade breakage

## Phase 4: PicoClaw Software Install (COMPLETE ✅)
- [x] install-picocrush.sh — Ollama with CUDA, 9 default models, MAXN power mode
- [x] install-picoclaw.sh — Docker containers (ThreadWeaver, OpenClaw, Portal, Caddy)
- [x] Blinkt! LED status daemon with scanner, blink, look-around behaviors
- [x] ThreadWeaver chat UI with Ollama model discovery
- [x] OpenClaw agent with all channel SDK dependencies
- [x] Caddy HTTPS reverse proxy for OpenClaw dashboard
- [x] PicoClaw portal landing page (port 80) with live status
- [x] validate-pair.sh — end-to-end health checks
- [x] update-threadweaver.sh — version check + rebuild
- [x] update-picoclaw.sh / update-picocrush.sh — update scripts
- [x] Auto-resize filesystem at install time

## Phase 5: Community Installer (PLANNED)
- [ ] picoclcaw-setup.sh — all-in-one for BYO hardware
- [ ] Auto-detect hardware (RPi5 vs Jetson)
- [ ] Interactive prompts for IP, models, options
- [ ] Harden + install + configure in one script

## Phase 6: Enhancements (PLANNED)
- [ ] Telegram/Discord channel integration for mobile access
- [ ] Ollama model auto-discovery in OpenClaw (upstream feature request)
- [ ] Blinkt! firework effects for specific actions
- [ ] Blinkt! on picocrush (requires Jetson GPIO pinmux device tree overlay)
- [ ] Pre-built Docker images on Docker Hub (skip build on RPi5)
- [ ] Production HTTPS with Let's Encrypt (for public-facing deployments)

## Power Budget (Measured)

| Scenario | Power | Annual Cost |
|----------|------:|------------:|
| Idle (both nodes) | 14W | $19.62 |
| Typical (inference + orchestration) | 20W | $28.03 |
| Realistic blend (90% idle) | 15W | $21.02 |
| Peak (all subsystems maxed) | 35W | $49.06 |

PSU: 50W (15W headroom at peak)

## Installed Models (9 default)

| Model | Size | Type |
|-------|-----:|------|
| llama3.2:3b | 2.0 GB | General (primary) |
| llama3.1:8b | 4.9 GB | General (quality) |
| gemma3:4b | 3.3 GB | General (multilingual) |
| phi3.5:3.8b | 2.2 GB | Reasoning |
| deepseek-r1:7b | 4.7 GB | Reasoning (chain-of-thought) |
| qwen2.5:3b | 1.9 GB | Code |
| starcoder2:3b | 1.7 GB | Code |
| llava:7b | 4.7 GB | Vision |
| moondream:1.8b | 1.7 GB | Vision |

## Notes
- OpenClaw has had significant security issues in early 2026 — runs in Docker container with hardening
- Ollama replaced llama-server for native multi-model management and auto-discovery
- ThreadWeaver requires patches for LAN access (API_BASE, Vite proxy, model discovery) — baked into Docker build
- Orin Nano GPIO pinmux does not support Blinkt! on physical pins 16/18 — RPi5 only
- 128GB+ microSD required for picoclaw (Docker + OpenClaw + ThreadWeaver)
