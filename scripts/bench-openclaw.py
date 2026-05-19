#!/usr/bin/env python3
"""
OpenClaw Model Benchmark Suite
Runs progressively complex tasks across all configured models via the live
gateway and reports pass/fail, latency, and token usage per model.

Usage (from host):
  ssh picocluster@clusterclaw.local "docker exec openclaw python3 /home/openclaw/files/bench.py"

Usage (with options):
  docker exec openclaw python3 /home/openclaw/files/bench.py --models qwen3.5:4b,granite4.1:8b
  docker exec openclaw python3 /home/openclaw/files/bench.py --tiers 1,2
  docker exec openclaw python3 /home/openclaw/files/bench.py --output /home/openclaw/files/results.json
  docker exec openclaw python3 /home/openclaw/files/bench.py --quick   # tiers 1+2 only

Tier 1 — Basic inference (no tools, tests model reachability + reasoning)
Tier 2 — Single tool call (write, read, list)
Tier 3 — Multi-step tool chaining
Tier 4 — Harder reasoning + tool use
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

# ── Models ────────────────────────────────────────────────────────────────────

ALL_MODELS = [
    "qwen3.5:4b",
    "qwen3.5:9b",
    "granite4.1:8b",
    "llama3.1:8b",
    "llama3.2:3b",
    "phi3.5:3.8b",
    "nemotron-3-nano:4b",
    "ministral-3:8b",
    "gemma4:e4b",
    "deepseek-r1:7b",
]

# Models known not to support function calling in Ollama — skip tool-use tiers
NO_TOOLS_MODELS = {"deepseek-r1:7b"}

# ── Tests ─────────────────────────────────────────────────────────────────────
# check(text, meta) → bool
#   text: the agent/model's reply string
#   meta: result["meta"] dict from openclaw agent JSON (has toolSummary, durationMs, agentMeta)
#   For infer runs meta is {}

WORKSPACE = "/home/openclaw/files"

TESTS = [
    # ── Tier 1: raw inference, no tools ──────────────────────────────────────
    {
        "id": "t1-ping",
        "tier": 1,
        "name": "Reply 'pong'",
        "mode": "infer",
        "prompt": "Reply with exactly one word: pong",
        "check": lambda text, _: "pong" in text.lower(),
        "timeout": 90,
    },
    {
        "id": "t1-math",
        "tier": 1,
        "name": "17 × 13 = 221",
        "mode": "infer",
        "prompt": (
            "What is 17 multiplied by 13? "
            "Reply with only the number, nothing else."
        ),
        "check": lambda text, _: "221" in text,
        "timeout": 90,
    },
    {
        "id": "t1-json",
        "tier": 1,
        "name": "Output valid JSON",
        "mode": "infer",
        "prompt": (
            'Reply with a single valid JSON object with exactly two keys: '
            '"status" set to "ok" and "count" set to 42. '
            "No explanation, just the JSON object."
        ),
        "check": lambda text, _: _check_json(text, {"status": "ok", "count": 42}),
        "timeout": 90,
    },
    # ── Tier 2: single tool call ──────────────────────────────────────────────
    {
        "id": "t2-list",
        "tier": 2,
        "name": "List workspace files",
        "mode": "agent",
        "prompt": (
            "List the files in your workspace directory and tell me "
            "exactly how many files are present."
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 1 and
            any(c.isdigit() for c in text)
        ),
        "timeout": 120,
    },
    {
        "id": "t2-read",
        "tier": 2,
        "name": "Read SOUL.md",
        "mode": "agent",
        "prompt": (
            "Read the file SOUL.md in your workspace. "
            "What is the name that appears after the # on the very first line?"
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 1 and
            "claw" in text.lower()
        ),
        "timeout": 120,
    },
    {
        "id": "t2-write",
        "tier": 2,
        "name": "Write file",
        "mode": "agent",
        "prompt": (
            "Write a file called bench-write.txt in your workspace "
            "containing exactly this text: hello-bench"
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 1 and
            (
                "wrote" in text.lower() or
                "created" in text.lower() or
                "successfully" in text.lower() or
                "hello-bench" in text.lower()
            ) and
            _verify_file(f"{WORKSPACE}/bench-write.txt", "hello-bench")
        ),
        "timeout": 120,
        "cleanup": [f"{WORKSPACE}/bench-write.txt"],
    },
    # ── Tier 3: multi-step chaining ───────────────────────────────────────────
    {
        "id": "t3-write-read",
        "tier": 3,
        "name": "Write then read back",
        "mode": "agent",
        "prompt": (
            "Do exactly two things in order:\n"
            "1. Write a file called bench-chain.txt with the content: verify-abc-123\n"
            "2. Read that file back and tell me what it contains."
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 2 and
            "verify-abc-123" in text
        ),
        "timeout": 120,
        "cleanup": [f"{WORKSPACE}/bench-chain.txt"],
    },
    {
        "id": "t3-compute-write",
        "tier": 3,
        "name": "Compute then write",
        "mode": "agent",
        "prompt": (
            "Calculate 2 to the power of 10. "
            "Then write a file called bench-math.txt containing only that number."
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 1 and
            (
                "1024" in text or
                "wrote" in text.lower() or
                "successfully" in text.lower()
            ) and
            _verify_file(f"{WORKSPACE}/bench-math.txt", "1024")
        ),
        "timeout": 120,
        "cleanup": [f"{WORKSPACE}/bench-math.txt"],
    },
    # ── Tier 4: harder multi-step ─────────────────────────────────────────────
    {
        "id": "t4-edit",
        "tier": 4,
        "name": "Write, edit, verify",
        "mode": "agent",
        "prompt": (
            "Do these steps:\n"
            "1. Write a file called bench-edit.txt with the content: version-1\n"
            "2. Replace its content with: version-2\n"
            "3. Read it back and confirm what it now contains."
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 3 and
            "version-2" in text and
            "version-1" not in text.split("version-2")[0].replace("Replace", "")
        ),
        "timeout": 150,
        "cleanup": [f"{WORKSPACE}/bench-edit.txt"],
    },
    {
        "id": "t4-summary",
        "tier": 4,
        "name": "Read, list, summarise",
        "mode": "agent",
        "prompt": (
            "Do these steps:\n"
            "1. Read SOUL.md from your workspace.\n"
            "2. List all files in your workspace.\n"
            "3. Write a one-sentence summary into bench-summary.txt that "
            "mentions the name from SOUL.md and how many files are in the workspace.\n"
            "4. Tell me what you wrote."
        ),
        "check": lambda text, meta: (
            _tool_calls(meta) >= 3 and
            "bench-summary.txt" in text.lower() and
            "claw" in text.lower()
        ),
        "timeout": 180,
        "cleanup": [f"{WORKSPACE}/bench-summary.txt"],
    },
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def _tool_calls(meta):
    return meta.get("toolSummary", {}).get("calls", 0)

def _verify_file(path, expected):
    try:
        with open(path) as f:
            return expected in f.read()
    except Exception:
        return False

def _check_json(text, expected):
    # Extract the first {...} block from the response
    import re
    m = re.search(r'\{[^{}]*\}', text, re.DOTALL)
    if not m:
        return False
    try:
        obj = json.loads(m.group())
        return all(obj.get(k) == v for k, v in expected.items())
    except Exception:
        return False

def _cleanup(paths):
    for p in paths:
        try:
            os.remove(p)
        except FileNotFoundError:
            pass

# ── Runners ───────────────────────────────────────────────────────────────────

def preload_model(base_url, model_id, timeout=300):
    """
    Warm the model by sending a trivial generate directly to Ollama.
    First evicts any currently-loaded model so the swap starts clean.
    Bypasses the OpenClaw gateway so we can use a long timeout without
    affecting the benchmark clock.
    Returns (True, elapsed_s) on success, (False, elapsed_s) on failure.
    """
    import urllib.request, urllib.error
    root = base_url.split("/v1")[0].rstrip("/")

    # Evict whatever is currently loaded before requesting the new model.
    # This prevents cascading failures where a timed-out load poisons the next.
    try:
        with urllib.request.urlopen(f"{root}/api/ps", timeout=5) as r:
            ps = json.loads(r.read())
        for m in ps.get("models", []):
            if m["name"] != model_id:
                payload = json.dumps({"model": m["name"], "keep_alive": 0}).encode()
                req = urllib.request.Request(
                    f"{root}/api/generate", data=payload,
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=15) as r2:
                    r2.read()
    except Exception:
        pass  # best-effort; proceed regardless

    url = f"{root}/api/generate"
    payload = json.dumps({"model": model_id, "prompt": "hi", "stream": False}).encode()
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
            return True, time.monotonic() - t0
    except Exception:
        return False, time.monotonic() - t0


def current_ollama_model(base_url):
    """Return the model name currently loaded in Ollama (via /api/ps), or None."""
    import urllib.request
    root = base_url.split("/v1")[0].rstrip("/")
    try:
        with urllib.request.urlopen(f"{root}/api/ps", timeout=5) as r:
            data = json.loads(r.read())
            models = data.get("models", [])
            return models[0]["name"] if models else None
    except Exception:
        return None


def run_infer(model, prompt, timeout=60):
    """Raw inference via openclaw infer model run --gateway."""
    t0 = time.monotonic()
    try:
        r = subprocess.run(
            [
                "openclaw", "infer", "model", "run",
                "--gateway", "--json",
                "--model", f"local/{model}",
                "--prompt", prompt,
            ],
            capture_output=True, text=True, timeout=timeout,
        )
        elapsed_ms = int((time.monotonic() - t0) * 1000)
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip()[:300]
            return None, {}, elapsed_ms, f"exit {r.returncode}: {err}"
        data = json.loads(r.stdout)
        if not data.get("ok"):
            return None, {}, elapsed_ms, f"not ok: {json.dumps(data)[:200]}"
        text = (data.get("outputs") or [{}])[0].get("text", "")
        return text, {}, elapsed_ms, None
    except subprocess.TimeoutExpired:
        return None, {}, int(timeout * 1000), "TIMEOUT"
    except json.JSONDecodeError as e:
        return None, {}, int((time.monotonic() - t0) * 1000), f"JSON error: {e}"
    except Exception as e:
        return None, {}, int((time.monotonic() - t0) * 1000), str(e)


def run_agent(model, prompt, timeout=120):
    """Full agent run (with tools) via openclaw agent --json."""
    session_id = str(uuid.uuid4())
    t0 = time.monotonic()
    try:
        r = subprocess.run(
            [
                "openclaw", "agent",
                "--agent", "main",
                "--model", f"local/{model}",
                "--session-id", session_id,
                "--json",
                "--timeout", str(timeout),
                "--message", prompt,
            ],
            capture_output=True, text=True, timeout=timeout + 30,
        )
        elapsed_ms = int((time.monotonic() - t0) * 1000)
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip()[:300]
            return None, {}, elapsed_ms, f"exit {r.returncode}: {err}"
        data = json.loads(r.stdout)
        if data.get("status") != "ok":
            # Return a sentinel the caller can recognise as a timeout
            if data.get("status") == "timeout":
                return None, {}, elapsed_ms, "TIMEOUT"
            return None, {}, elapsed_ms, f"status={data.get('status')}: {json.dumps(data)[:200]}"
        text = (data.get("result", {}).get("payloads") or [{}])[0].get("text", "")
        meta = data.get("result", {}).get("meta", {})
        # Prefer gateway-reported durationMs
        elapsed_ms = meta.get("durationMs", elapsed_ms)
        return text, meta, elapsed_ms, None
    except subprocess.TimeoutExpired:
        return None, {}, int(timeout * 1000), "TIMEOUT"
    except json.JSONDecodeError as e:
        return None, {}, int((time.monotonic() - t0) * 1000), f"JSON error: {e}"
    except Exception as e:
        return None, {}, int((time.monotonic() - t0) * 1000), str(e)


# ── Output ────────────────────────────────────────────────────────────────────

ANSI = sys.stdout.isatty()

def c(code, text):
    return f"\033[{code}m{text}\033[0m" if ANSI else text

def status_cell(s):
    if s == "PASS":      return c("32", "PASS")
    if s == "FAIL":      return c("31", "FAIL")
    if s == "SKIP":      return c("33", "SKIP")
    if s == "TIMEOUT":   return c("33", "TIME")
    if s == "LOAD_FAIL": return c("35", "LOAD")
    return c("31", "ERR ")


# ── Pre-flight ────────────────────────────────────────────────────────────────

def check_ollama(base_url):
    """Return (ok, message). Hits /api/tags to verify Ollama is reachable."""
    import urllib.request, urllib.error
    # base_url is like http://host:port/v1 — strip to http://host:port
    root = base_url.split("/v1")[0].rstrip("/")
    url = f"{root}/api/tags"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read())
            models = [m["name"] for m in data.get("models", [])]
            return True, f"{len(models)} models loaded"
    except urllib.error.URLError as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


def evict_loaded_models(base_url):
    """Evict any model currently resident in Ollama to free VRAM before benchmarking."""
    import urllib.request
    root = base_url.split("/v1")[0].rstrip("/")
    try:
        with urllib.request.urlopen(f"{root}/api/ps", timeout=5) as r:
            data = json.loads(r.read())
            loaded = [m["name"] for m in data.get("models", [])]
    except Exception:
        return
    for model_name in loaded:
        try:
            payload = json.dumps({"model": model_name, "keep_alive": 0}).encode()
            req = urllib.request.Request(
                f"{root}/api/generate", data=payload,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=15) as r:
                r.read()
            print(c("33", f"  evicted {model_name} from VRAM"), flush=True)
        except Exception as e:
            print(c("33", f"  could not evict {model_name}: {e}"), flush=True)


def get_ollama_base_url():
    """Read baseUrl from openclaw config."""
    import subprocess
    try:
        r = subprocess.run(
            ["openclaw", "config", "get", "models.providers.local.baseUrl"],
            capture_output=True, text=True, timeout=5,
        )
        url = r.stdout.strip()
        if url.startswith("http"):
            return url
    except Exception:
        pass
    return "http://localhost:11434/v1"


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="OpenClaw Model Benchmark Suite")
    parser.add_argument("--models", help="Comma-separated model IDs (default: all)")
    parser.add_argument("--tiers", help="Comma-separated tier numbers, e.g. 1,2 (default: all)")
    parser.add_argument("--quick", action="store_true", help="Tiers 1+2 only (fast sanity check)")
    parser.add_argument(
        "--output",
        default=f"{WORKSPACE}/bench-results.json",
        help="Where to write JSON results",
    )
    parser.add_argument("--no-cleanup", action="store_true", help="Leave test files on disk")
    parser.add_argument(
        "--ollama-url",
        default=None,
        help="Override Ollama base URL (e.g. http://crush:11434/v1); defaults to openclaw config",
    )
    args = parser.parse_args()

    # ── Pre-flight: verify Ollama is reachable ────────────────────────────────
    ollama_url = args.ollama_url if args.ollama_url else get_ollama_base_url()
    ok, msg = check_ollama(ollama_url)
    if ok:
        print(c("32", f"✓ Ollama reachable ({msg}) at {ollama_url}"))
        evict_loaded_models(ollama_url)
    else:
        print(c("31", f"✗ Ollama unreachable at {ollama_url}: {msg}"))
        print(c("31", "  Aborting — fix Ollama before running the benchmark."))
        sys.exit(1)

    models = [m.strip() for m in args.models.split(",")] if args.models else ALL_MODELS
    if args.quick:
        tier_filter = {1, 2}
    elif args.tiers:
        tier_filter = {int(t) for t in args.tiers.split(",")}
    else:
        tier_filter = None
    tests = [t for t in TESTS if tier_filter is None or t["tier"] in tier_filter]

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    print(c("36", f"\nOpenClaw Model Benchmark — {ts}"))
    print(f"Models : {', '.join(models)}")
    print(f"Tests  : {len(tests)} tasks (tiers {sorted(set(t['tier'] for t in tests))})")
    print()

    # Column widths
    M_W = max(len(m) for m in models) + 1
    T_W = 5  # status cell width
    ID_W = max(len(t["id"]) for t in tests)

    # Header row
    header = f"{'Model':<{M_W}}"
    for t in tests:
        header += f"  {t['id'][:T_W]:>{T_W}}"
    header += f"  {'ok':>4}  {'avg ms':>8}"
    sep = "-" * len(header)
    print(header)
    print(sep)

    all_results = {
        "timestamp": ts,
        "models": models,
        "tests": [{"id": t["id"], "tier": t["tier"], "name": t["name"]} for t in tests],
        "runs": {},
    }

    for model in models:
        all_results["runs"][model] = {}
        no_tools = model in NO_TOOLS_MODELS

        # ── Pre-warm: load model into Ollama before timing any tests ──────────
        print(f"  Loading {model}...", flush=True)
        loaded, load_s = preload_model(ollama_url, model)  # uses default 300s
        active = current_ollama_model(ollama_url)
        if loaded:
            print(f"  {model} ready in {load_s:.0f}s  (Ollama reports: {active})", flush=True)
        else:
            print(
                c("31", f"  {model} failed to load in {load_s:.0f}s — skipping all tests"),
                flush=True,
            )
            row = f"{model:<{M_W}}"
            for test in tests:
                row += f"  {'LOAD':>{T_W}}"
            row += f"  0/{len(tests)}  {'':>8}"
            print(row, flush=True)
            for test in tests:
                all_results["runs"][model][test["id"]] = {
                    "status": "LOAD_FAIL",
                    "ms": int(load_s * 1000),
                    "reply": "", "tools": None,
                    "input_tokens": None, "output_tokens": None,
                    "error": "model failed to load within 180s",
                }
            continue

        row = f"{model:<{M_W}}"
        passes = 0
        durations = []

        for test in tests:
            tid = test["id"]
            mode = test["mode"]
            timeout = test.get("timeout", 90)
            status = None   # reset each iteration
            meta = {}       # reset each iteration

            # Clean up leftover files from a prior run
            if not args.no_cleanup:
                _cleanup(test.get("cleanup", []))

            # Skip tool tests for models known not to support tools
            if mode == "agent" and no_tools:
                status = "SKIP"
                elapsed_ms = 0
                text = ""
                err = "model does not support tool calling"
            elif mode == "infer":
                text, meta, elapsed_ms, err = run_infer(model, test["prompt"], timeout)
            else:
                text, meta, elapsed_ms, err = run_agent(model, test["prompt"], timeout)

            if status != "SKIP":
                if err:
                    status = "TIMEOUT" if "TIMEOUT" in err else "ERR"
                else:
                    try:
                        passed = test["check"](text or "", meta if mode == "agent" else {})
                    except Exception:
                        passed = False
                    status = "PASS" if passed else "FAIL"
                    if passed:
                        passes += 1

            if err != "model does not support tool calling":
                durations.append(elapsed_ms)

            row += f"  {status_cell(status):>{T_W}}"
            all_results["runs"][model][tid] = {
                "status": status,
                "ms": elapsed_ms,
                "reply": (text or "")[:300],
                "tools": _tool_calls(meta) if mode == "agent" else None,
                "input_tokens": (meta.get("agentMeta") or {}).get("usage", {}).get("input"),
                "output_tokens": (meta.get("agentMeta") or {}).get("usage", {}).get("output"),
                "error": err,
            }

        eligible = len([t for t in tests if not (t["mode"] == "agent" and no_tools)])
        avg_ms = int(sum(durations) / len(durations)) if durations else 0
        row += f"  {passes}/{eligible:<2}  {avg_ms:>7,}ms"
        print(row)

    print(sep)
    print()

    # Per-tier summary
    print(c("36", "Tier breakdown:"))
    for tier in sorted(set(t["tier"] for t in tests)):
        tier_tests = [t for t in tests if t["tier"] == tier]
        print(f"  T{tier}  ", end="")
        for t in tier_tests:
            print(f"  {t['id']:<{ID_W}}  {t['name']}", end="\n      ")
        print()

    # Per-model pass rate summary
    print(c("36", "Summary:"))
    for model in models:
        run = all_results["runs"][model]
        statuses = [v["status"] for v in run.values()]
        passes = statuses.count("PASS")
        total = len([s for s in statuses if s != "SKIP"])
        fails = [tid for tid, v in run.items() if v["status"] in ("FAIL", "ERR")]
        skips = statuses.count("SKIP")
        line = f"  {model:<{M_W}}  {passes}/{total}"
        if skips:
            line += f"  ({skips} skipped: no tools)"
        if fails:
            line += f"  FAILED: {', '.join(fails)}"
        print(line)

    # Save JSON
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults → {args.output}")


if __name__ == "__main__":
    main()
