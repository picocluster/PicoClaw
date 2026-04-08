#!/usr/bin/env python3
"""
PicoClaw LED status daemon — runs on picoclaw (RPi5).

Boot sequence:
  1. Rainbow sweep on startup
  2. Blue sweep waiting for network
  3. Amber progress waiting for services (OpenClaw + ThreadWeaver)
  4. Green flash when ready

Runtime status:
  - Breathing blue: idle, all services healthy
  - Green chase: LLM inference active (any client — ThreadWeaver or OpenClaw)
  - Amber pulse: service degraded (one service down)
  - Red pulse: all services down

Monitors:
  - OpenClaw gateway on http://127.0.0.1:18789
  - ThreadWeaver backend on http://127.0.0.1:8000
  - llama-server inference activity on http://picocrush:8080/slots
"""

import sys
import os
import time
import math
import signal
import json
import urllib.request
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apa102 import Blinkt, sweep, fill, pulse, rainbow_cycle, flash, NUM_LEDS

OPENCLAW_URL = "http://127.0.0.1:18789/__openclaw__/canvas/"
THREADWEAVER_URL = "http://127.0.0.1:8000/api/settings"
LLAMA_SLOTS_URL = "http://10.1.10.221:8080/slots"
LLAMA_HEALTH_URL = "http://10.1.10.221:8080/health"
BOOT_TIMEOUT = 120

running = True


def signal_handler(sig, frame):
    global running
    running = False


def http_check(url, timeout=2):
    """Quick HTTP check — returns True if response < 500."""
    try:
        req = urllib.request.Request(url, method="GET")
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status < 500
    except Exception:
        return False


def check_inference_active():
    """Check if llama-server on picocrush is actively generating tokens."""
    try:
        resp = urllib.request.urlopen(LLAMA_SLOTS_URL, timeout=2)
        slots = json.loads(resp.read())
        for slot in slots:
            if slot.get("state", 0) != 0:
                return True
        return False
    except Exception:
        return False


def check_network():
    """Check if network interface has an IP."""
    try:
        import subprocess
        result = subprocess.run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True, text=True, timeout=5,
        )
        return "default" in result.stdout
    except Exception:
        return False


def boot_sequence(leds):
    """Visual boot sequence — run once at startup."""
    # Stage 1: Rainbow — "I'm alive"
    rainbow_cycle(leds, cycles=1, delay=0.015, brightness=0.15)

    # Stage 2: Blue sweep — waiting for network
    for attempt in range(20):
        sweep(leds, 0, 0, 255, delay=0.04, brightness=0.3)
        if check_network():
            break

    # Stage 3: Blue fill — network up
    fill(leds, 0, 80, 255, delay=0.06, brightness=0.2)

    # Stage 4: Wait for services with amber progress
    start = time.time()
    services_ready = False
    while time.time() - start < BOOT_TIMEOUT and running:
        elapsed = time.time() - start
        filled = min(NUM_LEDS, int((elapsed / BOOT_TIMEOUT) * NUM_LEDS) + 1)

        # Check services
        openclaw_ok = http_check(OPENCLAW_URL)
        threadweaver_ok = http_check(THREADWEAVER_URL)
        llama_ok = http_check(LLAMA_HEALTH_URL)

        # Color reflects progress: amber waiting, green for each service found
        for i in range(NUM_LEDS):
            if i < filled:
                br = 0.1 + 0.15 * math.sin(time.time() * 3) ** 2
                # First 3 LEDs show service status
                if i == 0 and llama_ok:
                    leds.set_pixel(i, 0, 255, 0, br)
                elif i == 1 and threadweaver_ok:
                    leds.set_pixel(i, 0, 255, 0, br)
                elif i == 2 and openclaw_ok:
                    leds.set_pixel(i, 0, 255, 0, br)
                else:
                    leds.set_pixel(i, 255, 140, 0, br)
            else:
                leds.set_pixel(i, 0, 0, 40, 0.05)
        leds.show()
        time.sleep(0.15)

        # Need at least llama-server + one UI to be ready
        if llama_ok and (threadweaver_ok or openclaw_ok):
            flash(leds, 0, 255, 0, times=3, on_time=0.15, off_time=0.1, brightness=0.4)
            services_ready = True
            break

    if not services_ready:
        flash(leds, 255, 140, 0, times=3, on_time=0.2, off_time=0.1, brightness=0.3)

    return services_ready


def inference_pattern(leds, step):
    """Green chase — LLM is generating tokens."""
    pos = step % (NUM_LEDS * 2)
    for i in range(NUM_LEDS):
        dist = abs(i - (pos % NUM_LEDS))
        if dist > NUM_LEDS // 2:
            dist = NUM_LEDS - dist
        br = max(0.02, 0.4 * (1.0 - dist / 4.0))
        leds.set_pixel(i, 0, 255, 40, max(0, br))
    leds.show()


def idle_breathing(leds, step):
    """Breathing blue — idle state."""
    br = 0.03 + 0.12 * (math.sin(step * 0.05) ** 2)
    leds.set_all(0, 40, 255, br)
    leds.show()


def degraded_pattern(leds, step):
    """Amber pulse — some services down."""
    br = 0.05 + 0.2 * (math.sin(step * 0.08) ** 2)
    leds.set_all(255, 140, 0, br)
    leds.show()


def error_pattern(leds, step):
    """Red pulse — all services down."""
    br = 0.1 + 0.3 * (math.sin(step * 0.1) ** 2)
    leds.set_all(255, 0, 0, br)
    leds.show()


def runtime_loop(leds):
    """Main runtime loop — monitor services and inference activity."""
    step = 0
    # Cache service health (don't check every 100ms)
    openclaw_ok = False
    threadweaver_ok = False
    llama_ok = False
    inferencing = False

    while running:
        # Check inference activity frequently (every 500ms)
        if step % 5 == 0:
            inferencing = check_inference_active()

        # Check service health less frequently (every 5s)
        if step % 50 == 0:
            openclaw_ok = http_check(OPENCLAW_URL)
            threadweaver_ok = http_check(THREADWEAVER_URL)
            llama_ok = http_check(LLAMA_HEALTH_URL)

        services_up = sum([openclaw_ok, threadweaver_ok, llama_ok])

        if inferencing:
            inference_pattern(leds, step)
        elif services_up == 0:
            error_pattern(leds, step)
        elif services_up < 2:
            degraded_pattern(leds, step)
        else:
            idle_breathing(leds, step)

        step += 1
        time.sleep(0.1)


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    with Blinkt(platform="rpi5", brightness=0.2) as leds:
        boot_sequence(leds)
        if running:
            runtime_loop(leds)


if __name__ == "__main__":
    main()
