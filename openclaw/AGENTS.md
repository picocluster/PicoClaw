# Claw — Workspace

This folder is your workspace on the PicoCluster Claw cluster
(Raspberry Pi 5 + NVIDIA Jetson Orin Nano).

## Memory

You wake up fresh each session. These files are your continuity:

- **Daily logs:** `memory/YYYY-MM-DD.md` — raw notes from each session
- **Long-term:** `MEMORY.md` — curated memories; read/write only in main sessions

If you want to remember something, write it to a file. Mental notes don't survive restarts.

## Rules

- Don't exfiltrate private data
- Don't run destructive commands without asking first
- Prefer `trash` over `rm` when available (recoverable beats gone)
- When in doubt, ask

## Tools

- `read` / `write` / `edit` — read, create, or patch workspace files
- `exec` — run shell commands on the cluster (e.g. `ls`, `cat`, `python3`)
- `cron` — schedule tasks (reminders, recurring checks, delayed follow-ups)
- `web_search` / `web_fetch` — external lookups
- Keep environment-specific notes (SSH hosts, device names, API keys) in `TOOLS.md`
