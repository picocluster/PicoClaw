#!/usr/bin/env python3
"""Patch ThreadWeaver server.py to support llama-server model discovery."""
import sys

server_py = sys.argv[1] if len(sys.argv) > 1 else "/opt/picoclcaw/threadweaver/backend/server.py"

with open(server_py, "r") as f:
    content = f.read()

old_func = '''@app.get("/api/models/local")
async def list_local_models():
    """List available models from the local Ollama instance."""
    import httpx
    base_url = config.get_base_url("local") or "http://localhost:11434"
    # Strip /v1 if present for the Ollama native API
    ollama_url = base_url.replace("/v1", "")
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{ollama_url}/api/tags")
            if resp.status_code == 200:
                data = resp.json()
                models = [
                    {
                        "name": m["name"],
                        "size": m.get("size", 0),
                        "modified": m.get("modified_at", ""),
                    }
                    for m in data.get("models", [])
                ]
                return {"models": models, "source": ollama_url}
            return {"models": [], "error": f"Status {resp.status_code}"}
    except Exception as e:
        return {"models": [], "error": str(e)}'''

new_func = '''@app.get("/api/models/local")
async def list_local_models():
    """List available models from local Ollama or llama-server."""
    import httpx
    base_url = config.get_base_url("local") or "http://localhost:11434"
    ollama_url = base_url.replace("/v1", "")
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            # Try Ollama API first
            try:
                resp = await client.get(f"{ollama_url}/api/tags")
                if resp.status_code == 200:
                    data = resp.json()
                    models = [
                        {"name": m["name"], "size": m.get("size", 0), "modified": m.get("modified_at", "")}
                        for m in data.get("models", [])
                    ]
                    if models:
                        return {"models": models, "source": ollama_url}
            except Exception:
                pass
            # Fallback: OpenAI-compatible /v1/models (llama-server, LM Studio, etc.)
            openai_url = base_url if "/v1" in base_url else f"{base_url}/v1"
            resp = await client.get(f"{openai_url}/models")
            if resp.status_code == 200:
                data = resp.json()
                model_list = data.get("data", data.get("models", []))
                models = [
                    {"name": m.get("id", m.get("name", "unknown")), "size": m.get("size", 0), "modified": ""}
                    for m in (model_list if isinstance(model_list, list) else [])
                ]
                return {"models": models, "source": openai_url}
            return {"models": [], "error": f"Status {resp.status_code}"}
    except Exception as e:
        return {"models": [], "error": str(e)}'''

if old_func in content:
    content = content.replace(old_func, new_func)
    with open(server_py, "w") as f:
        f.write(content)
    print("Patched successfully")
else:
    print("WARNING: Could not find the exact function to patch. Already patched?")
