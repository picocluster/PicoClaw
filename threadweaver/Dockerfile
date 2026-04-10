FROM node:24-slim

WORKDIR /app
RUN apt-get update && apt-get install -y git python3 python3-pip python3-venv curl && rm -rf /var/lib/apt/lists/*

# Clone ThreadWeaver
RUN git clone --depth 1 https://github.com/nosqltips/ThreadWeaver.git .

# Ensure threadweaver_config.json ships with a valid Ollama tool-use model.
# Whatever the upstream repo ships (gemma3:4b, a llamafile tag, etc.) gets
# replaced here so fresh installs start in a working state out of the box.
RUN cat > /app/backend/threadweaver_config.json <<'JSON'
{
  "default_provider": "local",
  "providers": {
    "anthropic": {
      "enabled": true,
      "api_key": "",
      "model": "claude-sonnet-4-20250514",
      "label": "Claude (Anthropic)"
    },
    "openai": {
      "enabled": true,
      "api_key": "",
      "model": "gpt-4",
      "base_url": "https://api.openai.com/v1",
      "label": "GPT (OpenAI)"
    },
    "gemini": {
      "enabled": true,
      "api_key": "",
      "model": "gemini-2.0-flash",
      "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
      "label": "Gemini (Google)"
    },
    "grok": {
      "enabled": true,
      "api_key": "",
      "model": "grok-3",
      "base_url": "https://api.x.ai/v1",
      "label": "Grok (xAI)"
    },
    "local": {
      "enabled": true,
      "api_key": "",
      "model": "llama3.1:8b",
      "base_url": "http://picocrush:11434/v1",
      "label": "Local (Ollama)"
    }
  }
}
JSON

# Patch API_BASE for LAN access
RUN sed -i "s|const API_BASE = 'http://localhost:8000/api'|const API_BASE = '/api'|g" \
    frontend/src/lib/api.ts frontend/src/routes/+page.svelte

# Patch vite config: allow LAN hosts + proxy /api to backend
RUN printf 'import { sveltekit } from "@sveltejs/kit/vite";\nimport { defineConfig } from "vite";\n\nexport default defineConfig({\n\tplugins: [sveltekit()],\n\tserver: {\n\t\tallowedHosts: true,\n\t\tproxy: {\n\t\t\t"/api": {\n\t\t\t\ttarget: "http://127.0.0.1:8000",\n\t\t\t\tchangeOrigin: true\n\t\t\t}\n\t\t}\n\t}\n});\n' > frontend/vite.config.js

# Patch model discovery for llama-server
COPY patch-llama-server.py /tmp/patch-llama-server.py
RUN python3 /tmp/patch-llama-server.py /app/backend/server.py && rm /tmp/patch-llama-server.py

# Install backend deps
RUN python3 -m venv /app/venv && /app/venv/bin/pip install --no-cache-dir -r backend/requirements.txt

# Install frontend deps
WORKDIR /app/frontend
RUN npm install

WORKDIR /app
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV LLM_PROVIDER=local
# Default Ollama tag (valid tool-use model). Overridden by docker-compose via
# LOCAL_BASE_URL / LOCAL_MODEL env vars. Must be an Ollama tag, not a .gguf
# filename, since we use picocrush Ollama for inference. llama3.1:8b chains
# tool calls reliably; see docs/faq.md #16 for the full tool-support matrix.
ENV LOCAL_BASE_URL=http://picocrush:11434/v1
ENV LOCAL_MODEL=llama3.1:8b

EXPOSE 5173 8000

CMD ["/app/start.sh"]
