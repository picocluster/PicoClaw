# Contributing to PicoCluster Claw

Thanks for your interest in contributing! PicoCluster Claw is an integration project that ties together several open-source components into a cohesive AI appliance. Contributions across the stack are welcome.

## What Lives Here

This repo contains the **glue** that makes the cluster work:

- Install and setup scripts (`scripts/setup/`)
- Docker Compose configuration and Dockerfiles
- Portal control panel (`portal/`)
- Blinkt! LED daemon (`leds/`)
- MCP tool servers (`mcp/`)
- User management scripts (`scripts/user-bin/`)
- Golden image build scripts (`scripts/setup/build-*.sh`)
- Documentation and the GitHub Pages site (`docs/`, `site/`)

The upstream projects have their own repos:

| Project | Repo | What to contribute there |
|---------|------|--------------------------|
| ThreadWeaver | [nosqltips/ThreadWeaver](https://github.com/nosqltips/ThreadWeaver) | Chat UI, LLM providers, conversation branching |
| OpenClaw | [openclaw/openclaw](https://github.com/openclaw/openclaw) | Agent framework, channels, Canvas dashboard |
| AgentStateGraph | [nosqltips/AgentStateGraph](https://github.com/nosqltips/AgentStateGraph) | State store, MCP server, speculations, epochs |
| Ollama | [ollama/ollama](https://github.com/ollama/ollama) | Model runtime, CUDA support |

## Getting Started

1. **Fork and clone** the repo
2. **Read the docs** in `docs/` to understand the architecture
3. **Set up a dev cluster** (RPi5 + Jetson Orin Nano, or test with VMs/containers)
4. **Make changes** on a feature branch
5. **Test on real hardware** if possible (especially LED, GPIO, and Ollama changes)
6. **Open a pull request** with a clear description

## Areas Where Help Is Needed

- **New MCP tool servers** (weather, RSS, home automation, etc.)
- **Portal improvements** (responsive design, dark/light toggle, real-time status via WebSocket)
- **Install script hardening** (error recovery, progress reporting, rollback)
- **Documentation** (tutorials, video guides, translated docs)
- **Testing on different hardware** (RPi4, other Jetson models, alternative SBCs)
- **Model benchmarking** (inference speed, quality comparisons, tool-use reliability)

## Development Guidelines

### Code Style

- **Shell scripts**: Use `set -euo pipefail`, quote variables, use `log()` for output
- **Python**: Follow the existing patterns in `mcp/` and `leds/` (stdlib-only where possible)
- **HTML/CSS**: No build tools. Single-file components. Dark theme. PicoCluster blue (`#1b75ba`) + red (`#e63946`)
- **Docker**: Keep images minimal. Use multi-stage builds where it helps

### Commit Messages

Write clear commit messages that explain **why**, not just what:

```
Good:  "Fix LED stuck in inference mode with OLLAMA_KEEP_ALIVE=30m"
Bad:   "Fix LED bug"
```

### Testing

- Test install scripts on fresh golden images when possible
- Test MCP servers by connecting them to ThreadWeaver and running example prompts
- Test LED changes by verifying physical LED behavior (not just API responses)
- Run `pc-status` on both nodes after any infrastructure change

### Hardware-Specific Notes

- **GPIO/LED changes**: The Blinkt! uses APA102 over GPIO via bit-bang (gpiod). Test on real hardware
- **Ollama/CUDA**: The Jetson uses JetPack 6 with CUDA. Desktop CUDA drivers behave differently
- **Unified memory**: The Jetson shares RAM between CPU and GPU. Memory pressure affects inference
- **Hostnames**: `clusterclaw` (RPi5) and `clustercrush` (Jetson). Install scripts auto-set these

## Pull Request Process

1. **One logical change per PR** (don't combine unrelated fixes)
2. **Describe what changed and why** in the PR description
3. **Include test results** if you tested on hardware (screenshots of LEDs, `pc-status` output, etc.)
4. **Update docs** if your change affects user-facing behavior
5. A maintainer will review and merge or request changes

## Reporting Issues

Open an issue on GitHub with:

- **What you expected** vs **what happened**
- **Which node** (clusterclaw, clustercrush, or both)
- **Relevant logs** (`pc-status` output, `sudo docker logs threadweaver`, `journalctl -u ollama`)
- **Hardware** (RPi5 RAM size, Jetson model)

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
