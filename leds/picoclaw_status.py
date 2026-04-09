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
from led_api import start_api_server, get_state

OPENCLAW_URL = "http://127.0.0.1:18789/"
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
    """Check if Ollama is actively generating by monitoring /api/generate endpoint activity.
    Uses /api/ps but compares expires_at to detect fresh vs stale model loading."""
    try:
        resp = urllib.request.urlopen(OLLAMA_PS_URL, timeout=2)
        data = json.loads(resp.read())
        models = data.get("models", [])
        if not models:
            return False
        # Check if expires_at was recently refreshed (within last 10 seconds)
        # Ollama sets expires_at = now + 5min on each request
        for m in models:
            expires = m.get("expires_at", "")
            if expires:
                try:
                    from datetime import datetime, timezone
                    # Parse ISO timestamp with timezone
                    exp_str = expires.replace("Z", "+00:00")
                    # Handle nanoseconds by truncating to microseconds
                    if "." in exp_str:
                        parts = exp_str.split(".")
                        frac_and_tz = parts[1]
                        # Find where the timezone starts (+ or -)
                        for ti, c in enumerate(frac_and_tz):
                            if c in "+-" and ti > 0:
                                frac = frac_and_tz[:ti][:6]
                                tz = frac_and_tz[ti:]
                                exp_str = parts[0] + "." + frac + tz
                                break
                    exp_time = datetime.fromisoformat(exp_str)
                    now = datetime.now(timezone.utc)
                    # Ollama sets 5min expiry. If >4min50s remain, inference just happened
                    remaining = (exp_time - now).total_seconds()
                    if remaining > 290:  # More than 4:50 remaining = just used
                        return True
                except Exception:
                    pass
        return False
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
    """Manages the idle state with scanner, color drift, fade, and look-around behavior."""

    # Behavior modes
    MODE_SCAN = "scan"          # Normal back-and-forth scanning
    MODE_LOOK_AROUND = "look"   # Stop center, look left, pause, look right, pause, resume

    def __init__(self):
        self.scanner_pos = 0
        self.scanner_dir = 1
        self.tick = 0
        self.move_every = 3  # move one pixel every N frames (~6 moves/sec at 18fps)
        self.color_idx = 0.0
        self.color_speed = 0.003
        self.fade_target = 0.15
        self.fade_current = 0.15
        self.next_fade_time = time.time() + random.uniform(15, 40)
        self.firework_pixels = {}

        # Behavior state
        self.mode = self.MODE_SCAN
        self.next_look_time = time.time() + random.uniform(8, 18)
        self.look_step = 0      # which step of the look-around sequence
        self.look_pause = 0     # frames to pause before next look step
        # Look-around sequence: (target_position, pause_frames_after)
        self.look_sequence = [
            (3, 20),    # move to center, pause
            (0, 25),    # look left, pause
            (3, 15),    # back to center, brief pause
            (7, 25),    # look right, pause
            (3, 15),    # back to center, pause
        ]
        # Blink state
        self.next_blink_time = time.time() + random.uniform(3, 8)
        self.blink_frames = 0  # countdown when blinking

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

        # Check if it's time to switch to look-around mode
        if self.mode == self.MODE_SCAN and now >= self.next_look_time:
            self.mode = self.MODE_LOOK_AROUND
            self.look_step = 0
            self.look_pause = 0

        # Movement
        self.tick += 1
        if self.tick >= self.move_every:
            self.tick = 0

            if self.mode == self.MODE_SCAN:
                # Normal scanning
                self.scanner_pos += self.scanner_dir
                if self.scanner_pos >= NUM_LEDS - 1:
                    self.scanner_pos = NUM_LEDS - 1
                    self.scanner_dir = -1
                elif self.scanner_pos <= 0:
                    self.scanner_pos = 0
                    self.scanner_dir = 1

            elif self.mode == self.MODE_LOOK_AROUND:
                if self.look_pause > 0:
                    # Pausing — hold position
                    self.look_pause -= 1
                else:
                    # Move toward current look target
                    target, pause_after = self.look_sequence[self.look_step]
                    if self.scanner_pos < target:
                        self.scanner_pos += 1
                    elif self.scanner_pos > target:
                        self.scanner_pos -= 1
                    else:
                        # Arrived at target — pause then next step
                        self.look_pause = pause_after
                        self.look_step += 1
                        if self.look_step >= len(self.look_sequence):
                            # Done looking around — resume scanning
                            self.mode = self.MODE_SCAN
                            self.scanner_dir = random.choice([-1, 1])
                            self.next_look_time = now + random.uniform(10, 25)

        # Render — use RGB scaling for smooth falloff (APA102 brightness has only 31 steps)
        r, g, b = self.get_color()
        master = self.fade_current / 0.15  # normalized 0-1 for fade to black

        # Blink — quick off/on
        if now >= self.next_blink_time and self.blink_frames == 0:
            self.blink_frames = 4  # ~220ms at 18fps (2 frames off, 2 frames dim)
            self.next_blink_time = now + random.uniform(3, 10)
        if self.blink_frames > 0:
            self.blink_frames -= 1
            if self.blink_frames >= 2:
                leds.clear()
                leds.show()
                return
            master *= 0.3

        for i in range(NUM_LEDS):
            # Check for firework on this pixel first
            if i in self.firework_pixels:
                fr, fg, fb, fbr, fstep = self.firework_pixels[i]
                fbr *= 0.88  # decay
                fstep += 1
                if fbr < 0.02 or fstep > 25:
                    del self.firework_pixels[i]
                else:
                    self.firework_pixels[i] = (fr, fg, fb, fbr, fstep)
                    leds.set_pixel(i, int(fr * fbr), int(fg * fbr), int(fb * fbr), 0.3)
                    continue

            # Scanner glow — one bright pixel, one dim neighbor
            dist = abs(i - self.scanner_pos)
            if dist == 0:
                intensity = 1.0
            elif dist == 1:
                intensity = 0.12
            else:
                intensity = 0.0

            intensity *= master

            if intensity < 0.005:
                leds.set_pixel(i, 0, 0, 0, 0)
            else:
                leds.set_pixel(i, int(r * intensity), int(g * intensity), int(b * intensity), 0.2)

        leds.show()


# ─── Active effects ─────────────────────────────────────────

class InferenceEngine:
    """Colorful chase when LLM is generating."""

    COLORS = [
        (0, 255, 40),     # green
        (0, 200, 255),    # cyan
        (100, 255, 0),    # lime
        (0, 255, 180),    # mint
        (50, 150, 255),   # sky blue
        (180, 255, 0),    # yellow-green
    ]

    def __init__(self):
        self.step = 0

    def update(self, leds):
        self.step += 1
        pos = (self.step * 0.3) % (NUM_LEDS * 2)
        color_idx = (self.step // 15) % len(self.COLORS)
        r, g, b = self.COLORS[color_idx]

        for i in range(NUM_LEDS):
            dist = abs(i - (pos % NUM_LEDS))
            if dist > NUM_LEDS // 2:
                dist = NUM_LEDS - dist
            intensity = max(0, 1.0 - dist / 3.0)

            leds.set_pixel(i, int(r * intensity), int(g * intensity), int(b * intensity), 0.3)

        leds.show()


# ─── API-driven patterns ────────────────────────────────────

def api_status_pattern(leds, state, step):
    """Solid color with gentle pulse — set_status."""
    r, g, b = state["color"] or (0, 60, 255)
    br = 0.15 + 0.1 * (math.sin(step * 0.08) ** 2)
    leds.set_all(r, g, b, br)
    leds.show()


def api_progress_pattern(leds, state, step):
    """Progress bar fill — set_progress."""
    r, g, b = state["color"] or (0, 255, 0)
    percent = state["percent"]
    filled = percent * NUM_LEDS / 100.0

    for i in range(NUM_LEDS):
        if i < int(filled):
            leds.set_pixel(i, r, g, b, 0.25)
        elif i < filled + 1:
            # Partial fill on the edge pixel
            frac = filled - int(filled)
            leds.set_pixel(i, int(r * frac), int(g * frac), int(b * frac), 0.2)
        else:
            leds.set_pixel(i, 0, 0, 0, 0)
    leds.show()


def api_pulse_success(leds, step):
    """Firework-style green burst then fade."""
    phase = step % 30
    if phase < 5:
        # Burst outward from center
        center = NUM_LEDS // 2
        spread = phase
        for i in range(NUM_LEDS):
            dist = abs(i - center)
            if dist <= spread:
                leds.set_pixel(i, 0, 255, 80, 0.4)
            else:
                leds.set_pixel(i, 0, 0, 0, 0)
    else:
        # Fade out
        intensity = max(0, 1.0 - (phase - 5) / 20.0)
        leds.set_all(0, int(255 * intensity), int(80 * intensity), 0.3 * intensity)
    leds.show()


def api_pulse_error(leds, step):
    """Quick red flashes."""
    phase = step % 12
    if phase < 3:
        leds.set_all(255, 0, 0, 0.4)
    elif phase < 6:
        leds.clear()
    elif phase < 9:
        leds.set_all(255, 0, 0, 0.3)
    else:
        leds.clear()
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
        # Check API state first — tool calls override everything
        api = get_state()
        if api["mode"] == "status":
            api_status_pattern(leds, api, step)
            step += 1
            time.sleep(0.055)
            continue
        elif api["mode"] == "progress":
            api_progress_pattern(leds, api, step)
            step += 1
            time.sleep(0.055)
            continue
        elif api["mode"] == "pulse_success":
            api_pulse_success(leds, step)
            step += 1
            time.sleep(0.055)
            continue
        elif api["mode"] == "pulse_error":
            api_pulse_error(leds, step)
            step += 1
            time.sleep(0.055)
            continue

        # Normal monitoring
        if step % 5 == 0:
            inferencing = check_inference_active()

        # Transition effects
        if inferencing and not was_inferencing:
            flash(leds, 255, 255, 255, times=1, on_time=0.05, off_time=0.0, brightness=0.3)
        elif not inferencing and was_inferencing:
            flash(leds, 0, 255, 80, times=2, on_time=0.08, off_time=0.05, brightness=0.3)
            idle = IdleEngine()
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
        time.sleep(0.055)


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Start LED control API on port 7777 (localhost only)
    start_api_server(port=7777)

    with Blinkt(platform="rpi5", brightness=0.2) as leds:
        # Skip boot sequence if services are already running (daemon restart)
        services_ready = (
            http_check(THREADWEAVER_URL, timeout=1)
            or http_check(OLLAMA_HEALTH_URL, timeout=1)
        )
        if not services_ready:
            boot_sequence(leds)
        if running:
            runtime_loop(leds)


if __name__ == "__main__":
    main()
