# PicoClaw LED Tools

## LED Control API

The Blinkt! LED strip on picoclaw is controlled via a simple HTTP API on `localhost:7777`.

### Endpoints

| Endpoint | Method | Body | Effect |
|----------|--------|------|--------|
| `/set_status` | POST | `{"color": "blue"}` | Solid color pulse |
| `/set_progress` | POST | `{"percent": 50, "color": "green"}` | Progress bar fill |
| `/pulse_success` | POST | `{}` | Green burst animation |
| `/pulse_error` | POST | `{}` | Red flash animation |
| `/clear` | POST | `{}` | Return to idle scanner |

### Colors

`red`, `green`, `blue`, `amber`, `cyan`, `purple`, `white`, `off`

### Options

- `duration` (seconds) — auto-clear after this time. 0 = stay until cleared.
- `message` — descriptive text (for logging, not displayed on LEDs).
- `percent` (0-100) — for progress bar.

## Using from ThreadWeaver

Add this to your project's system prompt in ThreadWeaver to let the LLM control the LEDs:

```
You have access to the PicoClaw Blinkt! LED strip via the run_command tool.
To control the LEDs, use curl commands:

Set a color: curl -sf -X POST http://localhost:7777/set_status -d '{"color":"COLOR"}'
Available colors: red, green, blue, amber, cyan, purple, white

Show progress: curl -sf -X POST http://localhost:7777/set_progress -d '{"percent":NUMBER,"color":"COLOR"}'

Success flash: curl -sf -X POST http://localhost:7777/pulse_success
Error flash: curl -sf -X POST http://localhost:7777/pulse_error
Reset to scanner: curl -sf -X POST http://localhost:7777/clear

Use these to give visual feedback. Show progress on multi-step tasks.
Flash success when done. Flash error on failures. Use colors creatively
to express mood or status. Always clear when done.
```

## Using from OpenClaw

The LED bridge (`openclaw-led-bridge.service`) automatically monitors OpenClaw agent events and triggers LEDs:

- Agent starts thinking → purple
- Agent uses a tool → cyan
- Agent completes → green burst
- Agent errors → red flash
- Returns to scanner after 5s idle

## Using from the Portal

The PicoClaw portal at `http://picoclaw` has an LED Control section with color buttons, effects, and a progress slider.

## Using from scripts

```bash
# Solid color
curl -X POST localhost:7777/set_status -d '{"color":"purple"}'

# Progress bar
curl -X POST localhost:7777/set_progress -d '{"percent":75,"color":"cyan"}'

# Celebratory flash
curl -X POST localhost:7777/pulse_success

# Error flash
curl -X POST localhost:7777/pulse_error

# Back to scanner
curl -X POST localhost:7777/clear

# Timed status (auto-clears after 5 seconds)
curl -X POST localhost:7777/set_status -d '{"color":"amber","duration":5}'
```
