# Jetson Orin Nano Super Dev Kit — Benchmark Report

**Board:** NVIDIA Jetson Orin Nano Super (8GB, JetPack 6.2, R36.4.3)
**CUDA:** 12.6, Compute Capability 8.7
**Storage:** 57GB eMMC (root) + 938GB NVMe
**Runtime:** llama.cpp (CUDA build, fbd441c37)
**Date:** 2026-04-02
**Configuration:** Headless (no USB devices, no video, no cameras)

---

## LLM Inference Performance (tokens/sec)

| Model | Test | 15W | 25W | MAXN | 15W→MAXN Gain |
|-------|------|----:|----:|-----:|--------------:|
| **TinyLlama 1.1B** (Q4_K_M, 636MB) | Prompt (pp512) | 1,026 | 1,398 | **1,506** | +47% |
| | Generation (tg128) | 35.3 | 47.8 | **51.1** | +45% |
| **Phi-3 3.8B** (Q4, 2.23GB) | Prompt (pp512) | 350 | 492 | **537** | +53% |
| | Generation (tg128) | 12.2 | 16.0 | **16.9** | +39% |
| **Llama 3.2 3B** (Q4_K_M, 1.87GB) | Prompt (pp512) | 479 | 650 | **713** | +49% |
| | Generation (tg128) | 13.3 | 17.2 | **18.4** | +38% |

---

## Power Draw — SoC Only (VDD_IN, Run 1)

| Test | 15W Mode | 25W Mode | MAXN |
|------|--------:|--------:|-----:|
| **Idle** | 5.2W | 5.5W | 9.1W |
| **CPU-only stress** (6 cores) | 7.6W | 8.0W | 9.1W |
| **TinyLlama inference** | 10.3W avg / 11.1W peak | 12.7W avg / 13.6W peak | 14.0W avg / 15.0W peak |
| **Phi-3 3.8B inference** | 11.7W avg / 12.5W peak | 14.6W avg / 15.3W peak | 16.0W avg / 16.9W peak |
| **Llama 3.2 3B inference** | 11.2W avg / 11.9W peak | 13.4W avg / 14.4W peak | 15.0W avg / 16.0W peak |
| **Combined CPU+GPU** | 6.8W avg / **14.5W peak** | 8.4W avg / **17.0W peak** | 9.9W avg / **19.3W peak** |

---

## Power Draw — Headless Max with I/O (Run 2)

### Individual Subsystem Power Contribution (MAXN)

| Subsystem | Avg Power | Peak Power | Notes |
|-----------|--------:|--------:|-------|
| **Idle baseline** | 5.7W | 5.7W | MAXN, no load, post-soak |
| **NVMe I/O only** (fio seq+rand) | 7.0W | 7.6W | +1.9W over idle |
| **Network only** (iperf3 GbE flood) | 6.0W | 6.5W | +0.3-0.8W over idle |
| **GPU inference only** (Phi-3) | 16.0W | 16.9W | Dominates power budget |

### Kitchen Sink — All Subsystems Simultaneously (CPU + GPU + NVMe + Network)

| Mode | Avg Power | Peak Power | Max Tj |
|------|--------:|--------:|------:|
| **15W** | 8.3W | **14.9W** | 60.5C |
| **25W** | 8.2W | **17.4W** | 62.8C |
| **MAXN** | 8.5W | **20.0W** | 64.5C |

### Sustained Thermal Soak — 5 Minutes at MAXN (All Subsystems)

| Metric | Value |
|--------|------:|
| **Peak power** | **20.4W** |
| **Sustained power (under full load)** | 17.2-20.2W |
| **Tj at start** | 51.2C |
| **Tj peak (at ~4 min)** | 71.0C |
| **Tj stabilized** | 67-68C |
| **Tj after cooldown** | 49.7C |
| **GPU clock start** | 1015 MHz |
| **GPU clock end** | 1013 MHz |
| **Thermal throttling** | **None** |
| **Performance degradation** | **None** |

### Inference Stability Over 5-Minute Soak (8 consecutive runs)

| Run | Phi-3 pp1024 (t/s) | Phi-3 tg256 (t/s) |
|-----|------------------:|------------------:|
| 1 | 473.92 | 16.67 |
| 2 | 473.31 | 16.69 |
| 3 | 474.01 | 16.51 |
| 4 | 474.48 | 16.95 |
| 5 | 476.90 | 16.96 |
| 6 | 475.50 | 16.98 |
| 7 | 477.03 | 16.98 |
| 8 | 476.61 | 16.97 |

*Performance actually improved slightly as components warmed up. Zero degradation.*

---

## CPU Performance (stress-ng bogo ops/s)

| Mode | Bogo ops/s | CPU Freq |
|------|--------:|------:|
| 15W | 1,052 | 1497 MHz |
| 25W | 944 | 1344 MHz |
| MAXN | **1,215** | 1728 MHz |

*Note: 25W mode scored lower than 15W on CPU — 25W sets CPU to 1344 MHz vs 15W's 1497 MHz. The 25W budget goes more to GPU clocks (914 MHz vs 611 MHz).*

---

## NVMe Performance (fio)

| Test | Throughput |
|------|--------:|
| Sequential write (1M blocks) | 915 MB/s |
| Sequential read (1M blocks) | 1,456 MB/s |
| Random 4K read (4 jobs) | 144 MB/s |
| Random 4K write (4 jobs) | 145 MB/s |

---

## Network Performance (iperf3 to picollm3)

| Direction | Throughput |
|-----------|--------:|
| Upload (4 streams) | 457 Mbits/sec |
| Download (4 streams) | 522 Mbits/sec |

---

## GPU Clock Frequencies by Power Mode

| Mode | GPU Clock |
|------|--------:|
| 15W | 611 MHz |
| 25W | 911-917 MHz |
| MAXN | 1011-1019 MHz |

---

## Thermal Analysis — No Throttling Detected

| Observation | Detail |
|-------------|--------|
| **Max junction temp** | 71.0C (MAXN 5-min soak, all subsystems) |
| **Thermal throttle threshold** | ~97C (Orin Nano) |
| **Headroom** | ~26C below throttle point |
| **GPU clock stability** | Rock solid across all tests — no frequency drops |
| **Thermal stabilization** | Peaks at ~70C after 4 min, settles to 67-68C |
| **Cooldown** | Returns to 50C within ~5 min after load stops |

### Per-Test Thermal Detail (Run 1)

| Test | Start Tj | End Tj | Max Tj | GPU Clock (start/end) |
|------|--------:|------:|------:|-------------------:|
| 15W TinyLlama | 50.1C | 52.7C | 53.3C | 611 / 611 |
| 15W Phi-3 | 51.9C | 56.3C | 57.9C | 611 / 611 |
| 15W Llama 3.2 | 56.0C | 57.8C | 58.8C | 611 / 611 |
| 25W TinyLlama | 50.3C | 54.4C | 54.4C | 916 / 911 |
| 25W Phi-3 | 51.9C | 58.5C | 59.3C | 914 / 914 |
| 25W Llama 3.2 | 56.1C | 58.8C | 60.4C | 912 / 914 |
| MAXN TinyLlama | 51.5C | 56.2C | 56.2C | 1018 / 1011 |
| MAXN Phi-3 | 50.7C | 60.3C | 60.3C | 1012 / 1017 |
| MAXN Llama 3.2 | 56.1C | 60.1C | 61.9C | 1015 / 1017 |

---

## PicoCluster Power Budget (Headless, Per Node)

| Scenario | Power Draw |
|----------|--------:|
| **Idle (MAXN)** | 5.7W |
| **Typical inference load** | 15-17W |
| **Absolute worst case (all subsystems, MAXN)** | **20.4W** |

### Recommended PSU Sizing

| Cluster Size | Min PSU (at measured max) | Recommended (20% margin) |
|-------------|--------:|--------:|
| 1 node | 21W | **25W** |
| 2 nodes | 41W | **50W** |
| 4 nodes | 82W | **100W** |
| 5 nodes | 102W | **125W** |

---

## Key Takeaways

1. **True headless max power: 20.4W at MAXN** — even with CPU, GPU, NVMe, and network all saturated simultaneously
2. **MAXN gives ~40-53% more inference throughput** over 15W for only ~5W more actual draw
3. **The board never reaches its 25W MAXN envelope** — the 8GB Orin Nano simply can't draw that much without USB/video/camera peripherals
4. **Zero thermal throttling** — peaked at 71C under sustained full load, 26C below the throttle point
5. **Zero performance degradation** — inference speed was rock steady across 8 consecutive runs during the 5-min soak
6. **Generation speed is memory-bandwidth limited** — 12-18 tok/s on 3B models regardless of how hard you push the GPU
7. **NVMe adds ~2W, network adds <1W** to the power budget — the GPU dominates
8. **Budget 25W per node with 20% margin** for PSU sizing in a headless cluster

---

## PDU Testing — 12V Passthrough, 1.5A Rated USB-A Ports

### Graduated Load Test Results (12V, MAXN)

| Test | Avg Power | Peak Power | Peak Current | Status |
|------|--------:|--------:|--------:|--------|
| **Idle (MAXN)** | 6.75W | 6.75W | 0.56A | ✅ Safe |
| **CPU stress** (6 cores) | ~10.0W | 10.2W | 0.85A | ✅ Safe |
| **TinyLlama 1.1B** | 14.9W | 17.5W | 1.46A | ⚠️ Borderline |
| **Llama 3.2 3B** | 18.0W | 19.0W | 1.58A | ❌ Over 1.5A spec |
| **Phi-3 3.8B** | 19.3W | 20.2W | 1.68A | ❌ Over 1.5A spec |
| **Kitchen sink** (all subsystems) | 11.3W | 21.7W | 1.81A | ❌ 21% over spec |

### 5-Minute Sustained Max Soak (12V PDU, All Subsystems, MAXN)

| Metric | Value |
|--------|------:|
| **Min power** | 8.3W |
| **Avg power** | 20.0W |
| **Peak power** | **21.7W** |
| **Peak current** | **1.81A at 12V** |
| **Tj start** | 53.4C |
| **Tj avg** | 70.8C |
| **Tj max** | 73.0C |
| **Tj end** | 71.9C |
| **Throttling** | None |
| **Brownout / crash** | None |
| **PDU port temp** | Cool to touch |

### Graduated Load Test — Port 3 (12V, MAXN)

| Test | Avg Power | Peak Power | Peak Current | Status |
|------|--------:|--------:|--------:|--------|
| **Idle (MAXN)** | 6.76W | 6.76W | 0.57A | ✅ Safe |
| **CPU stress** (6 cores) | ~10.3W | 10.25W | 0.85A | ✅ Safe |
| **TinyLlama 1.1B** | — | 17.5W | 1.46A | ⚠️ Borderline |
| **Llama 3.2 3B** | — | 18.9W | 1.57A | ❌ Over 1.5A spec |
| **Phi-3 3.8B** | — | 20.1W | 1.68A | ❌ Over 1.5A spec |

### 5-Minute Sustained Max Soak — Port 3 (12V, All Subsystems, MAXN)

| Metric | Value |
|--------|------:|
| **Peak power** | **21.73W** |
| **Peak current** | **1.81A at 12V** |
| **Max Tj** | 73.3C |
| **Throttling** | None |
| **Brownout / crash** | None |
| **PDU port temp** | Cool to touch |

### PDU Port Comparison — 12V, MAXN, 5-Minute Max Soak (All 3 Ports)

| Metric | Port 1 | Port 2 | Port 3 |
|--------|-------:|-------:|-------:|
| **Peak power** | 21.7W | 21.7W | 21.73W |
| **Peak current** | 1.81A | 1.81A | 1.81A |
| **Max Tj** | 73.0C | 73.2C | 73.3C |
| **Throttling** | None | None | None |
| **Brownout / crash** | None | None | None |
| **Port temp** | Cool | Cool | Cool |

### PDU Notes
- Ports are rated 1.5A but held 1.81A sustained for 5 minutes without failure across all 3 ports
- All PDU components remained cool — suggests conservative rating or low-resistance implementation
- Inference performance was rock solid throughout the soak on all ports
- Results are highly consistent port-to-port (<1% variance on peak power/current, <0.3C on Tj)
- **For dev/test clusters:** Existing PDU appears viable — ports are clearly overbuilt vs. their 1.5A spec
- **For production clusters:** Further validation recommended, direct wiring to PSU is safest
- NVMe auto-mounts on boot via `/etc/fstab` with `nofail` ✅

---

## PicoCluster Claw Cluster Power Testing (In-Case, 2026-04-04)

**Configuration:** PicoCluster Claw acrylic case, 80x25mm case fan, PDU, 50W PSU
**Nodes:** clusterclaw (RPi5 8GB, Raspbian) + clustercrush (Orin Nano Super 8GB, MAXN)
**Measurement:** Kill-A-Watt at wall, tegrastats on Orin, vcgencmd PMIC on RPi5

### In-Case Thermal Comparison (Orin Nano)

| Test | Out-of-Case Tj Peak | In-Case Tj Peak | Improvement |
|------|--------------------:|----------------:|------------:|
| **CPU-only stress (5 min)** | 64.5C | 54.4C | **-10.1C** |
| **Kitchen sink + GPU inference (5 min)** | 71.0C | 65.4C | **-5.6C** |

Case fan provides significant cooling benefit. No throttling in either configuration.

### RPi5 Thermals (In-Case, with heatsink)

| State | Temperature |
|-------|----------:|
| Idle | 31.2C |
| CPU + matrix + I/O stress (peak) | 67.5C |
| Post-cooldown | 33.4C |

### Cluster Power Draw (Kill-A-Watt at Wall)

| State | Kill-A-Watt | Notes |
|-------|----------:|-------|
| **Both idle** | **13-14W** | Baseline |
| **Both under CPU/IO stress** (no GPU inference) | **21-22W** | RPi5 headroom-limited |
| **Both max + GPU inference** | **~35W** (estimated) | Orin peaks at 21.6W SoC |

### Component Power Breakdown

| Component | Idle | Typical (agent workload) | Peak (kitchen sink) |
|-----------|-----:|-------------------------:|--------------------:|
| RPi5 (clusterclaw) | ~3W | ~4W | 7.5W |
| Orin Nano (clustercrush) | ~6W | ~10W | 20W |
| 12V fan | ~2W | ~2W | ~2W |
| PDU | ~1W | ~1W | ~1W |
| PSU efficiency loss (~15%) | ~2W | ~2.5W | ~4.5W |
| **Total per pair** | **~14W** | **~19.5W** | **~35W** |

### Orin Nano Tegrastats Summary (In-Case, Kitchen Sink + GPU Inference)

| Metric | Value |
|--------|------:|
| VDD_IN peak | 21.6W |
| VDD_IN sustained | 20.8-21.5W |
| VDD_CPU_GPU_CV peak | 11.7W |
| VDD_SOC peak | 4.5W |
| GPU utilization | 92-99% @ 1014-1017 MHz |
| CPU utilization | 94-100% @ 1728 MHz (6 cores) |
| Tj peak (in case) | 65.4C |
| Tj at start | 49.9C |
| Throttling | None |

### Agent Workload Power Estimate

Real-world OpenClaw agent loop is bursty (inference → wait for browser → observe → repeat):

| Phase | Duration | Orin Power |
|-------|----------|--------:|
| Inference (token generation) | ~12s | ~16W |
| Idle (waiting for browser action) | ~25s | ~6W |
| **Weighted cycle average** | ~37s | **~9-10W** |

Agent is idle (waiting for user commands) 90%+ of the time.

### Energy Cost Estimates

US average electricity: $0.16/kWh. PSU: 50W (15W headroom at peak).

| Scenario | Watts | kWh/month | kWh/year | $/month | $/year |
|----------|------:|----------:|---------:|--------:|-------:|
| **Idle** (waiting for tasks) | 14W | 10.1 | 122.6 | **$1.61** | **$19.62** |
| **Active agent workload** | 20W | 14.4 | 175.2 | **$2.30** | **$28.03** |
| **Peak** (all subsystems maxed) | 35W | 25.2 | 306.6 | **$4.03** | **$49.06** |
| **Realistic blend** (90% idle, 10% active) | 15W | 10.8 | 131.4 | **$1.73** | **$21.02** |

### Comparison

| Device | Typical Power | Annual Cost |
|--------|-------------:|-----------:|
| **PicoCluster Claw cluster** | **15W** | **~$21/year** |
| Desktop PC (always on) | ~80W | ~$112/year |
| Single GPU server (RTX 4090) | ~300W+ | ~$420+/year |
| 60W light bulb (always on) | 60W | ~$84/year |

*Your own private AI agent for under $2/month.*

---

## Raw Data Location

- Orin out-of-case benchmarks: `/mnt/nvme/results/` on clustercrush
- Orin in-case benchmarks: `/home/picocluster/results-incase/` on clustercrush
- RPi5 benchmarks: `/home/picocluster/results/` on clusterclaw

---

## OpenClaw Agent Benchmark

**Date:** 2026-05-19  
**Hardware:** Jetson Orin Nano Super 8GB (MAXN, Ollama CUDA)  
**Gateway:** OpenClaw 2026.5.12 via LiteLLM proxy  
**Context:** ~9,250 chars per request (optimized lean profile for local models)

The OpenClaw benchmark measures real agent capability across four tiers of increasing complexity — raw inference through multi-step tool chaining — using the live gateway, not a raw API.

| Tier | Tests | What it measures |
|---|---|---|
| T1 | ping, math, JSON | Raw inference, instruction following |
| T2 | list files, read, write | Single tool call with verification |
| T3 | write→read chain, compute→write | Multi-step tool chaining |
| T4 | write→edit→verify, read→summarize→write | Harder reasoning + tool use |

### Results (10 tasks, all tiers)

| Model | T1 | T2 | T3 | T4 | Score | Avg latency |
|---|:---:|:---:|:---:|:---:|:---:|---:|
| **granite4.1:8b** | 3/3 | 3/3 | 2/2 | 2/2 | **10/10** | 16,761 ms |
| qwen3.5:4b | 2/3 | 3/3 | 2/2 | 1/2 | **8/10** | 45,824 ms |
| nemotron-3-nano:4b | 3/3 | 2/3 | 1/2 | 0/2 | **6/10** | 43,067 ms |
| llama3.2:3b | 3/3 | 1/3 | 0/2 | 0/2 | **5/10** | 8,957 ms |

`granite4.1:8b` is the clear default: perfect score across all tiers and 2-3× faster than the alternatives.

### Context optimization that enabled these scores

Earlier runs with the default OpenClaw context showed granite scoring 5/10 and qwen scoring 3/10 — small models were overwhelmed before they could reason about the actual task.

Key changes:

| Change | Saved | Impact |
|---|---:|---|
| Replaced full workspace file templates with minimal stubs | ~12,000 chars | Eliminated boilerplate injection |
| Reduced tool schema via deny list | ~5,400 chars | Removed session, node, media tools |
| Removed dead remote-node tools (`file_fetch`, `dir_list`, `dir_fetch`, `file_write`) | ~2,580 chars | Always fail without a paired node; confused models |
| Fixed `t2-list`: `exec ls` instead of `dir_list` | — | `dir_list` requires unconfigured remote node ACL |

**Total context: ~11,800 → ~9,250 chars per request for local models**

### Cloud model context

Cloud models added to OpenClaw (Anthropic Claude, OpenAI GPT, etc.) automatically receive the **full unrestricted tool set** via OpenClaw's `tools.byProvider` policy. The `local` provider gets the lean profile; all other providers get browser automation, TTS, image/video/music generation, and all workspace tools. No config changes are needed when adding a cloud API key.
