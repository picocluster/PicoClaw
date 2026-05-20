# PicoCluster Claw Deployment Plan

## Overview

Three deployment paths, all ending at the same result: a secured PicoCluster Claw pair (claw + crush) running OpenClaw → llama-server.

---

## Part 1: Golden Image Creation

Strip down and harden base OS images. These become the PicoCluster-distributed images that ship with the product.

### 1A: RPi5 Golden Image (Raspbian)

Start with existing PicoCluster Raspbian image, then:

**Strip:**
- Remove desktop/GUI packages (if present)
- Remove LibreOffice, games, Wolfram, Sonic Pi, etc.
- Remove Bluetooth packages (no BT needed in cluster)
- Remove Avahi/mDNS (static IPs, not needed)
- Remove printing (cups)
- Remove unused locales
- Purge cached apt packages
- Clean up /tmp, logs, bash history

**Harden:**
- SSH: disable password auth, disable root login, key-only
- Firewall (ufw): deny all incoming, allow SSH (22)
- Fail2ban: protect SSH
- Unattended security updates (unattended-upgrades)
- Disable unused services (triggerhappy, bluetooth, avahi-daemon)
- Restrict /tmp (noexec mount option)
- Set file permissions: /etc/ssh/sshd_config 600
- Configure log rotation (journald max size)
- Set default user to `picocluster`
- Remove pi user if present
- Set hostname to `claw` (default, changed by configure-pair.sh)

**Pre-stage:**
- Install Node.js 24 (saves time during OpenClaw install)
- Install Docker (for containerized OpenClaw)
- Install ansible, ufw, fail2ban, unattended-upgrades
- Pre-configure NetworkManager for static IP template
- Include configure-pair.sh and ansible directory

**Output:** Minimal, hardened Raspbian image ready for `dd` capture and distribution.

**Script:** `build-rpi5-image.sh` — runs on a live RPi5, strips and hardens in place, then image with dd + jetson-shrink equivalent for Pi.

### 1B: Orin Nano Golden Image (Ubuntu/JetPack)

Start with fresh JetPack 6.x install, then:

**Strip:**
- Remove desktop/GUI packages (ubuntu-desktop, gdm3, gnome-*)
- Remove LibreOffice, Thunderbird, Firefox
- Remove unnecessary NVIDIA demo apps
- Remove Bluetooth packages
- Remove Avahi/mDNS
- Remove printing (cups)
- Purge cached apt packages
- Clean up /tmp, logs, bash history

**Harden:**
- SSH: disable password auth, disable root login, key-only
- Firewall (ufw): deny all incoming, allow SSH (22), allow port 8080 from claw IP only
- Fail2ban: protect SSH
- Unattended security updates
- Disable unused services
- Restrict /tmp
- Configure log rotation
- Set default user to `picocluster`
- Set hostname to `crush` (default, changed by configure-pair.sh)

**Pre-stage:**
- NVMe mount point (/mnt/nvme) in fstab with nofail
- CUDA/cuDNN validated (already in JetPack)
- Include configure-pair.sh
- Power mode persistence (MAXN systemd unit)

**Output:** Minimal, hardened JetPack image ready for `dd` capture → `jetson-shrink.sh` → gzip.

**Script:** `build-orin-image.sh` — runs on a live Orin Nano, strips and hardens in place.

---

## Part 2: PicoCluster Claw Software Install

Runs on golden images (or community images after Part 3 hardening). Installs and configures the full PicoCluster Claw stack.

### 2A: RPi5 (claw) — OpenClaw Install

**Script:** `install-claw.sh`

Steps:
1. Install Docker if not present
2. Pull/build OpenClaw Docker image
3. Configure OpenClaw:
   - `gateway.bind: "loopback"` (localhost only)
   - Token-based auth (auto-generate token)
   - `tools.fs.workspaceOnly: true`
   - `sandbox: "require"`
   - `plugins.allow: []` (no ClawHub skills by default)
   - `exec: "deny"` with `ask: "always"`
   - Deny control-plane tools (gateway, cron, sessions_spawn)
   - LLM endpoint → `http://crush:8080/v1` (uses /etc/hosts)
   - API key → "none" (llama-server doesn't need one)
4. Set file permissions: `chmod 600` on config, `chmod 700` on directories
5. Deploy systemd service for Docker container
6. Configure ufw:
   - Allow SSH (22)
   - Allow OpenClaw gateway (18789) from localhost only
   - Block 18791, 18792, 18800+ from all external
7. Run `openclaw security audit --fix` inside container
8. Enable and start service
9. Smoke test: health check, inference round-trip through crush

### 2B: Orin Nano (crush) — LLM Server Install

**Script:** `install-crush.sh`

Steps:
1. Mount NVMe if not mounted
2. Clone and build llama.cpp with CUDA (skip if binary exists)
3. Download default model set (~11GB)
4. Deploy llama-server systemd service
5. Configure ufw:
   - Allow SSH (22)
   - Allow port 8080 from claw IP only (not 0.0.0.0)
6. Set power mode to MAXN, persist via systemd
7. Enable and start llama-server
8. Smoke test: health check, inference test

### 2C: Pair Integration

**Script:** `configure-pair.sh` (already written)

Run on both nodes to set IPs, hostnames, /etc/hosts, and update all config files to point at each other.

**Validation script:** `validate-pair.sh`
- Ping both ways (claw ↔ crush)
- SSH both ways
- curl llama-server health from claw
- Inference round-trip from claw through crush
- Check ufw rules on both
- Check OpenClaw service health
- Check llama-server GPU memory usage
- Report pass/fail

---

## Part 3: Community Install (BYO Hardware)

For users who have their own RPi5 + Orin Nano (or similar) and their own OS images. Single script that does everything: harden + install + configure.

**Script:** `clusterclaw-setup.sh`

Usage:
```bash
# On RPi5:
curl -fsSL https://picocluster.com/clusterclaw/setup.sh | sudo bash -s claw

# On Orin Nano:
curl -fsSL https://picocluster.com/clusterclaw/setup.sh | sudo bash -s crush
```

Or download and run:
```bash
sudo ./clusterclaw-setup.sh claw --start-ip 192.168.1.50
sudo ./clusterclaw-setup.sh crush --start-ip 192.168.1.50
```

What it does:
1. Detect hardware (RPi5 vs Jetson via /proc/device-tree or nvidia-smi)
2. Detect OS (Raspbian vs Ubuntu)
3. Run hardening steps (Part 1 — strip + secure)
4. Run install steps (Part 2 — OpenClaw or llama-server)
5. Run configure-pair (set IPs, hostnames, hook them together)
6. Run validation
7. Print summary with next steps

Interactive prompts for:
- IP addressing (or accept defaults)
- Which models to download
- Whether to enable ClawHub skills (default: no)

---

## Model Selection & AI Context

### Which models appear where

| Interface | Models shown | Source |
|---|---|---|
| **OpenClaw** agent picker | granite4.1:8b, qwen3.5:4b, nemotron-3-nano:4b | Validated by benchmark — scores 6/10+ |
| **ThreadWeaver** model selector | All Ollama models | Pulls from Ollama `/api/tags` |

Pull any model with `ollama pull <model>` on clustercrush — it appears in ThreadWeaver immediately. OpenClaw's picker is curated to the three models with proven tool-calling reliability on 8GB hardware.

### Model-aware tool context

OpenClaw uses a two-tier context policy via `tools.byProvider`:

**Local models** (granite, qwen, nemotron — `local` provider) receive a lean schema (~9,250 chars):
- ✓ Workspace: `read`, `write`, `edit`
- ✓ Shell: `exec`
- ✓ Scheduling: `cron`
- ✓ Web: `web_search`, `web_fetch`
- ✗ Browser automation, TTS, image/video/music generation (saves ~2,500 chars of schema)

**Cloud models** (Anthropic Claude, OpenAI GPT, etc.) receive the full unrestricted schema automatically when you add an API key in OpenClaw settings. The provider key (`anthropic`, `openai`, etc.) matches the `byProvider` policy and the lean restriction is not applied — no extra configuration needed.

The remote-node file transfer tools (`file_fetch`, `dir_list`, `dir_fetch`, `file_write`) are excluded from all models — they require a paired remote node with explicit ACL policy not present in the default Claw setup.

### Adding a cloud model to OpenClaw

1. Open `https://claw.local` → Settings → Providers
2. Add your API key for Anthropic, OpenAI, or another supported provider
3. The cloud model appears in the OpenClaw model picker
4. It automatically receives the full tool set — browser automation, image generation, TTS, and all media tools are unblocked

---

## Phase Sequence

```
Phase 1: Image creation (you, internal)
  └── build-rpi5-image.sh
  └── build-orin-image.sh
  └── dd capture → shrink → gzip → distribute

Phase 2: Software install (runs on golden images)
  └── install-claw.sh (RPi5)
  └── install-crush.sh (Orin Nano)
  └── configure-pair.sh (both)
  └── validate-pair.sh (both)

Phase 3: Community installer (runs on any compatible hardware)
  └── clusterclaw-setup.sh (detects hardware, does everything)

Phase 4: Power draw testing
  └── Both nodes in PicoCluster Claw acrylic case
  └── Idle, inference, sustained load profiles
  └── Thermal validation in enclosure
  └── PDU load testing
```

---

## Scripts Summary

| Script | Where it runs | Purpose |
|--------|--------------|---------|
| `build-rpi5-image.sh` | RPi5 | Strip + harden Raspbian for golden image |
| `build-orin-image.sh` | Orin Nano | Strip + harden JetPack for golden image |
| `install-claw.sh` | RPi5 (claw) | Install OpenClaw in Docker, configure, secure |
| `install-crush.sh` | Orin Nano (crush) | Build llama.cpp, download models, deploy service |
| `configure-pair.sh` | Both | Set IPs, hostnames, hook nodes together |
| `validate-pair.sh` | Both | End-to-end health and connectivity checks |
| `clusterclaw-setup.sh` | Both (community) | All-in-one: harden + install + configure |
| `jetson-shrink.sh` | NUC (imaging) | Shrink dd-captured Orin images |
| `resize_ubuntu.sh` | Orin Nano | Expand rootfs after flashing |
| `sd-to-nvme.sh` | Orin Nano | Migrate SD card boot to NVMe |

---

## OpenClaw Security Hardening Checklist

Applied by install-claw.sh and clusterclaw-setup.sh:

- [ ] Run in Docker container (process isolation)
- [ ] Gateway bound to loopback only (127.0.0.1)
- [ ] Token-based auth (not password)
- [ ] `tools.fs.workspaceOnly: true`
- [ ] `sandbox: "require"` for delegated agents
- [ ] `plugins.allow: []` (no ClawHub skills by default)
- [ ] `exec: "deny"`, `ask: "always"`
- [ ] Control-plane tools denied (gateway, cron, sessions_spawn)
- [ ] Config file permissions: 600 (config), 700 (directories)
- [ ] `openclaw security audit --fix` run post-install
- [ ] ufw blocks all OpenClaw ports from external access
- [ ] llama-server port 8080 restricted to claw IP only
- [ ] No plaintext API keys in config (using local llama-server, key="none")
- [ ] SSH: key-only, no root, fail2ban
- [ ] Automatic security updates enabled

---

## Open Questions

1. **OpenClaw Docker image** — Is there an official one, or do we build from npm inside a node:24 container?
2. **OpenClaw version pinning** — Pin to a specific version or track latest? Given security history, pinning + manual updates seems safer.
3. **Model selection UI** — Should install-crush.sh be interactive (pick models) or use a default set?
4. **Chromium in Docker** — OpenClaw runs a browser. Need to verify headless Chromium works inside the container on ARM64.
5. **Vision model** — Still TBD whether OpenClaw needs screen vision. If yes, add Moondream2 to default model set.
6. **Community script distribution** — Host on picocluster.com or GitHub releases?
