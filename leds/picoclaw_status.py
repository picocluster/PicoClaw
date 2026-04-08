#!/usr/bin/env python3
"""
PicoClaw LED status daemon — runs on picoclaw (RPi5).

Boot sequence:
  Rainbow sweep → service discovery → green celebration

Runtime modes:
  - IDLE: Slow Larson scanner (Battlestar Galactica Cylon eye) with
    color drift — cycles through blues, purples, teals. Occasionally
    fades to black and back. Random firework sparkles.
  - INFERENCE: Fast green/cyan chase — LLM is generating tokens
  - DEGRADED: Slow amber pulse
  - ERROR: Red pulse

Monitors OpenClaw, ThreadWeaver, and Ollama on picocrush.
"""

import sys
import os
import time
import math
import signal
import json
import random
import urllib.request
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apa102 import Blinkt, sweep, fill, pulse, rainbow_cycle, flash, NUM_LEDS

OPENCLAW_URL = "http://127.0.0.1:18789/__openclaw__/canvas/"
THREADWEAVER_URL = "http://127.0.0.1:8000/api/settings"
OLLAMA_HEALTH_URL = "http://10.1.10.221:11434/api/tags"
OLLAMA_PS_URL = "http://10.1.10.221:11434/api/ps"
BOOT_TIMEOUT = 120

running = True

# Idle color palette — scanner drifts through these
IDLE_COLORS = [
    (0, 30, 255),     # blue
    (60, 0, 255),     # indigo
    (120, 0, 200),    # purple
    (0, 80, 200),     # teal-blue
    (0, 150, 180),    # teal
    (30, 0, 180),     # deep blue
    (80, 0, 255),     # violet
    (0, 60, 220),     # ocean blue
]


def signal_handler(sig, frame):
    global running
    running = False


def http_check(url, timeout=2):
    try:
        req = urllib.request.Request(url, method="GET")
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status < 500
    except Exception:
        return False


def check_inference_active():
    try:
        resp = urllib.request.urlopen(OLLAMA_PS_URL, timeout=2)
        data = json.loads(resp.read())
        models = data.get("models", [])
        return len(models) > 0
    except Exception:
        return False


def check_network():
    try:
        import subprocess
        result = subprocess.run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True, text=True, timeout=5,
        )
        return "default" in result.stdout
    except Exception:
        return False


# ─── Boot sequence ──────────────────────────────────────────

def boot_sequence(leds):
    rainbow_cycle(leds, cycles=1, delay=0.015, brightness=0.15)

    for attempt in range(20):
        sweep(leds, 0, 0, 255, delay=0.04, brightness=0.3)
        if check_network():
            break

    fill(leds, 0, 80, 255, delay=0.06, brightness=0.2)

    start = time.time()
    while time.time() - start < BOOT_TIMEOUT and running:
        elapsed = time.time() - start
        filled = min(NUM_LEDS, int((elapsed / BOOT_TIMEOUT) * NUM_LEDS) + 1)

        openclaw_ok = http_check(OPENCLAW_URL)
        threadweaver_ok = http_check(THREADWEAVER_URL)
        ollama_ok = http_check(OLLAMA_HEALTH_URL)

        for i in range(NUM_LEDS):
            if i < filled:
                br = 0.1 + 0.15 * math.sin(time.time() * 3) ** 2
                if i == 0 and ollama_ok:
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

        if ollama_ok and (threadweaver_ok or openclaw_ok):
            flash(leds, 0, 255, 0, times=3, on_time=0.15, off_time=0.1, brightness=0.4)
            return True

    flash(leds, 255, 140, 0, times=3, on_time=0.2, off_time=0.1, brightness=0.3)
    return False


# ─── Idle effects ───────────────────────────────────────────

class IdleEngine:
    """Manages the idle state with scanner, color drift, fade, and fireworks."""

    def __init__(self):
        self.scanner_pos = 0.0
        self.scanner_dir = 1
        self.scanner_speed = 0.08
        self.color_idx = 0.0
        self.color_speed = 0.003
        self.brightness_base = 0.15
        self.fade_target = 0.15
        self.fade_current = 0.15
        self.next_fade_time = time.time() + random.uniform(15, 40)
        self.next_firework_time = time.time() + random.uniform(8, 20)
        self.firework_pixels = {}  # {pixel_idx: (r, g, b, brightness, decay_step)}

    def get_color(self):
        """Get current scanner color from palette with smooth interpolation."""
        idx = int(self.color_idx) % len(IDLE_COLORS)
        next_idx = (idx + 1) % len(IDLE_COLORS)
        frac = self.color_idx - int(self.color_idx)

        r = int(IDLE_COLORS[idx][0] * (1 - frac) + IDLE_COLORS[next_idx][0] * frac)
        g = int(IDLE_COLORS[idx][1] * (1 - frac) + IDLE_COLORS[next_idx][1] * frac)
        b = int(IDLE_COLORS[idx][2] * (1 - frac) + IDLE_COLORS[next_idx][2] * frac)
        return r, g, b

    def update(self, leds):
        now = time.time()

        # Color drift
        self.color_idx += self.color_speed
        if self.color_idx >= len(IDLE_COLORS):
            self.color_idx -= len(IDLE_COLORS)

        # Fade to black and back
        if now >= self.next_fade_time:
            if self.fade_target > 0.02:
                self.fade_target = 0.0
                self.next_fade_time = now + random.uniform(3, 6)
            else:
                self.fade_target = random.uniform(0.1, 0.2)
                self.next_fade_time = now + random.uniform(20, 45)

        # Smooth fade transition
        diff = self.fade_target - self.fade_current
        self.fade_current += diff * 0.03

        # Scanner movement (Larson scanner / Cylon eye)
        self.scanner_pos += self.scanner_speed * self.scanner_dir
        if self.scanner_pos >= NUM_LEDS - 1:
            self.scanner_pos = NUM_LEDS - 1
            self.scanner_dir = -1
        elif self.scanner_pos <= 0:
            self.scanner_pos = 0
            self.scanner_dir = 1

        # Random firework
        if now >= self.next_firework_time:
            pixel = random.randint(0, NUM_LEDS - 1)
            fr = random.randint(180, 255)
            fg = random.randint(100, 255)
            fb = random.randint(100, 255)
            self.firework_pixels[pixel] = (fr, fg, fb, 0.5, 0)
            self.next_firework_time = now + random.uniform(5, 15)

        # Render
        r, g, b = self.get_color()

        for i in range(NUM_LEDS):
            # Scanner glow — bright at center, fading trail
            dist = abs(i - self.scanner_pos)
            if dist < 0.5:
                br = self.fade_current
            elif dist < 1.5:
                br = self.fade_current * 0.5
            elif dist < 2.5:
                br = self.fade_current * 0.15
            else:
                br = self.fade_current * 0.03

            # Check for firework on this pixel
            if i in self.firework_pixels:
                fr, fg, fb, fbr, step = self.firework_pixels[i]
                fbr *= 0.92  # decay
                step += 1
                if fbr < 0.01 or step > 30:
                    del self.firework_pixels[i]
                else:
                    self.firework_pixels[i] = (fr, fg, fb, fbr, step)
                    # Firework overrides scanner
                    leds.set_pixel(i, fr, fg, fb, fbr)
                    continue

            leds.set_pixel(i, r, g, b, max(0, br))

        leds.show()


# ─── Active effects ─────────────────────────────────────────

class InferenceEngine:
    """Fast green/cyan chase when LLM is generating."""

    def __init__(self):
        self.step = 0

    def update(self, leds):
        self.step += 1
        pos = (self.step * 0.3) % (NUM_LEDS * 2)

        for i in range(NUM_LEDS):
            dist = abs(i - (pos % NUM_LEDS))
            if dist > NUM_LEDS // 2:
                dist = NUM_LEDS - dist
            br = max(0.01, 0.45 * (1.0 - dist / 3.5))

            # Alternate green and cyan
            if (self.step // 20) % 2 == 0:
                leds.set_pixel(i, 0, 255, 40, max(0, br))
            else:
                leds.set_pixel(i, 0, 200, 255, max(0, br))

        leds.show()


# ─── Other patterns ─────────────────────────────────────────

def degraded_pattern(leds, step):
    br = 0.05 + 0.2 * (math.sin(step * 0.06) ** 2)
    leds.set_all(255, 140, 0, br)
    leds.show()


def error_pattern(leds, step):
    br = 0.1 + 0.3 * (math.sin(step * 0.1) ** 2)
    leds.set_all(255, 0, 0, br)
    leds.show()


# ─── Main loop ──────────────────────────────────────────────

def runtime_loop(leds):
    idle = IdleEngine()
    inference = InferenceEngine()

    step = 0
    openclaw_ok = False
    threadweaver_ok = False
    ollama_ok = False
    inferencing = False
    was_inferencing = False

    while running:
        # Check inference frequently
        if step % 5 == 0:
            inferencing = check_inference_active()

        # Transition effects
        if inferencing and not was_inferencing:
            # Just started inferencing — quick white flash
            flash(leds, 255, 255, 255, times=1, on_time=0.05, off_time=0.0, brightness=0.3)
        elif not inferencing and was_inferencing:
            # Just finished — brief green flash then back to idle
            flash(leds, 0, 255, 80, times=2, on_time=0.08, off_time=0.05, brightness=0.3)
            idle = IdleEngine()  # reset scanner position
        was_inferencing = inferencing

        # Check service health less frequently
        if step % 50 == 0:
            openclaw_ok = http_check(OPENCLAW_URL)
            threadweaver_ok = http_check(THREADWEAVER_URL)
            ollama_ok = http_check(OLLAMA_HEALTH_URL)

        services_up = sum([openclaw_ok, threadweaver_ok, ollama_ok])

        if inferencing:
            inference.update(leds)
        elif services_up == 0:
            error_pattern(leds, step)
        elif services_up < 2:
            degraded_pattern(leds, step)
        else:
            idle.update(leds)

        step += 1
        time.sleep(0.05)  # 20fps for smooth animations


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    with Blinkt(platform="rpi5", brightness=0.2) as leds:
        boot_sequence(leds)
        if running:
            runtime_loop(leds)


if __name__ == "__main__":
    main()
