FROM node:24-slim

WORKDIR /app
RUN apt-get update && apt-get install -y git python3 python3-pip python3-venv curl && rm -rf /var/lib/apt/lists/*

# ThreadWeaver source — CI: pre-populated tw-src/ from actions/checkout (no credentials needed)
# Local dev: tw-src/ is empty, falls back to git clone (requires network access to private repo)
COPY tw-src/ /tmp/tw-src/
RUN if [ -d "/tmp/tw-src/frontend" ]; then \
      cp -rT /tmp/tw-src /app; \
    else \
      git clone --depth 1 https://github.com/nosqltips/ThreadWeaver.git /app; \
    fi && rm -rf /tmp/tw-src

# Ensure threadweaver_config.json ships with a valid Ollama tool-use model.
COPY threadweaver_config.json /app/backend/threadweaver_config.json

# Patch API_BASE for LAN access — use find so missing files don't fail the build
RUN find frontend/src -name "*.ts" -o -name "*.svelte" | \
    xargs grep -rl "localhost:8000/api" 2>/dev/null | \
    xargs -r sed -i "s|http://localhost:8000/api|/api|g" || true

# Patch vite config: allow LAN hosts + proxy /api to backend
# Writes to both .ts and .js to cover either extension in the source tree
RUN printf 'import { sveltekit } from "@sveltejs/kit/vite";\nimport { defineConfig } from "vite";\n\nexport default defineConfig({\n\tplugins: [sveltekit()],\n\tserver: {\n\t\tallowedHosts: true,\n\t\tproxy: {\n\t\t\t"/api": {\n\t\t\t\ttarget: "http://127.0.0.1:8000",\n\t\t\t\tchangeOrigin: true\n\t\t\t}\n\t\t}\n\t}\n});\n' | tee frontend/vite.config.ts frontend/vite.config.js > /dev/null

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
# filename, since we use clustercrush Ollama for inference. llama3.1:8b chains
# tool calls reliably; see docs/faq.md #16 for the full tool-support matrix.
ENV LOCAL_BASE_URL=http://clustercrush:11434/v1
ENV LOCAL_MODEL=llama3.1:8b

EXPOSE 5173 8000

CMD ["/app/start.sh"]
