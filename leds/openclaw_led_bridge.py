#!/usr/bin/env python3
"""
OpenClaw → LED + Usage Bridge

Tails the OpenClaw container logs and fans out two side effects:

  1. **LED status** — color cycle: purple (thinking) → cyan (tool) →
     green/red pulse on end → idle clear. Same as before.
  2. **Usage attribution** — when CLAW_USAGE_URL is set, POSTs a
     `claw-usage` LLM-call event on every run end with whatever
     workflow/agent/model/tokens we can extract from the log line.

Both side effects are best-effort: a slow/dead LED API or usage
service must not stall log consumption. The bridge is also a no-op
on the usage side when CLAW_USAGE_URL is unset, so existing single-
purpose LED deployments don't change.
"""

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request


LED_API = os.getenv("CLAW_LED_URL", "http://127.0.0.1:7777")
USAGE_API = os.getenv("CLAW_USAGE_URL", "")  # empty = usage forwarding disabled
OPENCLAW_CONTAINER = os.getenv("CLAW_OPENCLAW_CONTAINER", "openclaw")
IDLE_TIMEOUT = 5  # seconds before clearing LED state


def _post(url: str, data: dict, timeout: float = 2.0) -> None:
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=timeout)
    except Exception:
        # Best-effort. Bridge mustn't block on a flaky downstream.
        pass


def led_call(endpoint: str, data: dict | None = None) -> None:
    _post(f"{LED_API}/{endpoint}", data or {})


def usage_post(event: dict) -> None:
    if not USAGE_API:
        return
    _post(f"{USAGE_API}/events/llm_call", event)


def caps_blocked(workflow: str | None, source: str = "openclaw") -> bool:
    """Returns True when the configured spending cap is breached and
    the run should be aborted. False on 200, network failure, or
    when caps aren't configured. Best-effort — a flaky usage
    service must NOT lock OpenClaw out of running.
    """
    if not USAGE_API or not workflow:
        return False
    try:
        from urllib.parse import urlencode
        qs = urlencode({"workflow": workflow, "source": source})
        url = f"{USAGE_API}/caps/check?{qs}"
        with urllib.request.urlopen(url, timeout=1.5) as resp:
            return resp.status == 429
    except urllib.error.HTTPError as e:
        return e.code == 429
    except Exception:
        return False


# Regex helpers for extracting fields from JSON-shaped log lines
# without committing to one parse strategy. OpenClaw's log format
# isn't a strict contract — we try several shapes and fall through
# to a sentinel event when we can't pin one down.
_RE_WORKFLOW = re.compile(r'"workflow"\s*:\s*"([^"]+)"')
_RE_AGENT = re.compile(r'"agent"\s*:\s*"([^"]+)"')
_RE_MODEL = re.compile(r'"model"\s*:\s*"([^"]+)"')
_RE_TOKENS_IN = re.compile(r'"(?:input_tokens|prompt_tokens|tokens_in)"\s*:\s*(\d+)')
_RE_TOKENS_OUT = re.compile(
    r'"(?:output_tokens|completion_tokens|tokens_out)"\s*:\s*(\d+)'
)


def _grep1(rx: re.Pattern[str], text: str) -> str | None:
    m = rx.search(text)
    return m.group(1) if m else None


def _grep_int(rx: re.Pattern[str], text: str) -> int:
    v = _grep1(rx, text)
    try:
        return int(v) if v else 0
    except ValueError:
        return 0


class RunState:
    """Tracks the in-flight run so the end event can compute a
    latency without OpenClaw having to surface it."""

    def __init__(self) -> None:
        self.started_at_ms: float | None = None
        self.workflow: str | None = None
        self.agent: str | None = None

    def start(self, line: str) -> None:
        self.started_at_ms = time.perf_counter() * 1000.0
        self.workflow = _grep1(_RE_WORKFLOW, line)
        self.agent = _grep1(_RE_AGENT, line)

    def end_payload(self, line: str, success: bool) -> dict:
        finished_ms = time.perf_counter() * 1000.0
        latency_ms = (
            finished_ms - self.started_at_ms if self.started_at_ms else 0.0
        )
        # Provider/model: best-effort. Default to local since the
        # appliance routes most agent runs to Ollama on clustercrush.
        provider = "openclaw"
        model = _grep1(_RE_MODEL, line) or "unknown"
        # OpenClaw may pass through provider info; if the model id
        # has a recognisable prefix, attribute. Otherwise stay
        # provider=openclaw so dashboards don't double-attribute.
        if model.startswith("gpt"):
            provider = "openai"
        elif model.startswith("claude"):
            provider = "anthropic"
        elif "/" in model:  # ollama-style "library/llama3.2:3b"
            provider = "local"
        return {
            "source": "openclaw",
            "workflow": self.workflow,
            "agent": self.agent,
            "provider": provider,
            "model": model,
            "tokens_in": _grep_int(_RE_TOKENS_IN, line),
            "tokens_out": _grep_int(_RE_TOKENS_OUT, line),
            "latency_ms": round(latency_ms, 1),
            "success": success,
            "error": None if success else "openclaw_run_error",
        }

    def reset(self) -> None:
        self.started_at_ms = None
        self.workflow = None
        self.agent = None


def main() -> None:
    print("OpenClaw bridge starting...")
    print(f"  LED API:       {LED_API}")
    print(f"  Usage API:     {USAGE_API or '(disabled)'}")
    print(f"  Container:     {OPENCLAW_CONTAINER}")

    last_event_time = time.time()
    is_active = False
    run = RunState()

    proc = subprocess.Popen(
        ["docker", "logs", "-f", "--since", "1s", OPENCLAW_CONTAINER],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    try:
        for line in proc.stdout:
            now = time.time()

            if "embedded_run_agent_start" in line or "agent:run:start" in line:
                led_call("set_status", {"color": "purple", "message": "thinking"})
                run.start(line)
                last_event_time = now
                is_active = True
                # Pre-flight cap check. When the workflow's daily cap
                # is breached, flash red and post an abort event;
                # OpenClaw can branch on this via its hook contract
                # (see hooks.json `agent:run:start` returning non-zero
                # to abort). The bridge just observes here — the
                # actual abort is OpenClaw's call.
                if caps_blocked(run.workflow):
                    led_call("set_status", {"color": "red", "message": "cap reached"})
                    usage_post(
                        {
                            "source": "openclaw",
                            "workflow": run.workflow,
                            "agent": run.agent,
                            "provider": "openclaw",
                            "model": "(blocked)",
                            "tokens_in": 0,
                            "tokens_out": 0,
                            "latency_ms": 0,
                            "success": False,
                            "error": "cap_breached",
                        }
                    )

            elif "tool_call" in line or "agent:tool" in line or "[tools]" in line:
                led_call("set_status", {"color": "cyan", "message": "using tool"})
                last_event_time = now
                is_active = True

            elif (
                "embedded_run_agent_end" in line and 'isError":false' in line
            ) or ("agent:run:end" in line and "error" not in line.lower()):
                led_call("pulse_success")
                usage_post(run.end_payload(line, success=True))
                run.reset()
                last_event_time = now
                is_active = True

            elif (
                "embedded_run_agent_end" in line and 'isError":true' in line
            ) or "agent:run:error" in line:
                led_call("pulse_error")
                usage_post(run.end_payload(line, success=False))
                run.reset()
                last_event_time = now
                is_active = True

            elif "message_send" in line or "Message delivered" in line:
                led_call("pulse_success")
                last_event_time = now

            if is_active and (now - last_event_time) > IDLE_TIMEOUT:
                led_call("clear")
                is_active = False

    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        led_call("clear")


if __name__ == "__main__":
    main()
