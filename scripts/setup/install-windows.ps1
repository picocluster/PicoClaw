#Requires -Version 5.1
# install-windows.ps1 — Install PicoCluster Claw on Windows
# Runs the same Docker stack as the cluster variant, with Ollama native (NVIDIA/AMD GPU or CPU).
#
# Usage (from PowerShell as Administrator):
#   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\install-windows.ps1 [-DefaultModel <model>] [-Tier large|small]
#
#   -DefaultModel : default Ollama model (default: qwen3.5:4b — matches the appliance)
#   -Tier large   : also pull 14B-class models (auto-prompted on 16 GB+ devices)
#   -Tier small   : skip the large-tier prompt

param(
    [string]$DefaultModel = "qwen3.5:4b",
    [ValidateSet("", "large", "small")]
    [string]$Tier = ""
)

$ErrorActionPreference = "Stop"

$INSTALL_DIR   = "$env:USERPROFILE\picocluster-claw"
$OPENCLAW_TOKEN = "picocluster-token"

# 8 GB-tier model set — matches the Claw appliance catalog so the desktop
# install behaves identically to the boxed hardware.
$MODELS = @(
    "qwen3.5:4b"
    "qwen3.5:9b"
    "granite4.1:8b"
    "llama3.1:8b"
    "deepseek-r1:7b"
    "ministral-3:8b"
    "nemotron-3-nano:4b"
    "phi3.5:3.8b"
    "llama3.2:3b"
    "gemma4:e4b"
)

# 16 GB+ tier — larger siblings of the same families. Opt-in: prompted
# automatically when the device has >= 16 GB of system memory.
$LARGE_MODELS = @(
    "qwen3.5:14b"
    "deepseek-r1:14b"
    "phi-4:14b"
)

function Log { param([string]$msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

function Command-Exists { param([string]$cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Wait-Url {
    param([string]$url, [int]$attempts = 30, [int]$delay = 2)
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -lt 500) { return $true }
        } catch {}
        if ($i -eq $attempts) { return $false }
        Start-Sleep $delay
    }
    return $false
}

Log "=== PicoCluster Claw — Windows Solo Install ==="
Log "  Model: $DefaultModel"
Log "  Install dir: $INSTALL_DIR"
Log ""

# ============================================================
# 1. Prerequisites
# ============================================================
Log "--- Step 1/6: Prerequisites ---"

# Windows version check
$os = [System.Environment]::OSVersion.Version
Log "  Windows: $([System.Environment]::OSVersion.VersionString)"
if ($os.Major -lt 10) {
    Log "ERROR: Windows 10 or later required."
    exit 1
}

# winget
if (-not (Command-Exists winget)) {
    Log "  ERROR: winget not found."
    Log "  Install App Installer from the Microsoft Store, then re-run."
    Log "  https://apps.microsoft.com/store/detail/app-installer/9NBLGGH4NNS1"
    exit 1
}
Log "  winget: $(winget --version)"

# Git
if (-not (Command-Exists git)) {
    Log "  Installing Git..."
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}
Log "  Git: $(git --version)"

# Docker Desktop
if (-not (Command-Exists docker)) {
    Log "  Installing Docker Desktop..."
    winget install --id Docker.DockerDesktop -e --source winget --accept-package-agreements --accept-source-agreements
    Log ""
    Log "  >>> Docker Desktop installed. Please:"
    Log "  >>> 1. Open Docker Desktop from the Start menu"
    Log "  >>> 2. Complete the setup wizard"
    Log "  >>> 3. Wait for Docker to show 'Running' in the system tray"
    Log "  >>> 4. Re-run this script"
    exit 0
}

# Check Docker is running
$dockerOk = $false
try { docker info 2>$null | Out-Null; $dockerOk = $true } catch {}
if (-not $dockerOk) {
    Log "  ERROR: Docker Desktop is installed but not running."
    Log "  >>> Open Docker Desktop from the Start menu, wait for it to start, then re-run."
    exit 1
}
Log "  Docker: $(docker version --format '{{.Server.Version}}' 2>$null)"

# Ollama
if (-not (Command-Exists ollama)) {
    Log "  Installing Ollama..."
    winget install --id Ollama.Ollama -e --source winget --accept-package-agreements --accept-source-agreements
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}
Log "  Ollama: $(ollama --version 2>$null)"

# GPU detection (informational)
if (Command-Exists nvidia-smi) {
    try {
        $gpu = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
        Log "  GPU (NVIDIA): $gpu"
    } catch { Log "  GPU: NVIDIA tools present but query failed" }
} else {
    Log "  GPU: NVIDIA not detected — Ollama will auto-detect or use CPU"
}

# ============================================================
# 2. Ollama setup
# ============================================================
Log "--- Step 2/6: Ollama ---"

# Ollama on Windows auto-starts as a tray app after install.
# If not running, start it in the background.
$ollamaReady = Wait-Url "http://localhost:11434/api/tags" -attempts 5 -delay 1
if (-not $ollamaReady) {
    Log "  Starting Ollama..."
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden -PassThru | Out-Null
    $ollamaReady = Wait-Url "http://localhost:11434/api/tags" -attempts 30 -delay 2
    if (-not $ollamaReady) {
        Log "  ERROR: Ollama failed to start. Try running 'ollama serve' manually."
        exit 1
    }
}
Log "  Ollama ready"

# ============================================================
# 3. Pull models
# ============================================================
Log "--- Step 3/6: Pull models ---"

# Decide whether to pull the 16 GB+ large tier.
$ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$pullLarge = $false

if ($Tier -eq "large") {
    $pullLarge = $true
    Log "  Tier: large (forced via -Tier large)"
} elseif ($Tier -eq "small") {
    Log "  Tier: small (forced via -Tier small) — skipping large models"
} elseif ($ramGB -ge 16) {
    Log "  Detected $ramGB GB RAM — large 14B-class models will fit."
    $reply = Read-Host "  Pull large-tier models too (qwen3.5:14b, deepseek-r1:14b, phi-4:14b)? [y/N]"
    if ($reply -match '^(?i)(y|yes)$') { $pullLarge = $true }
} else {
    Log "  Detected $ramGB GB RAM — staying on 8 GB-tier models."
}

foreach ($model in $MODELS) {
    Log "  Pulling $model..."
    & ollama pull $model 2>&1 | Select-Object -Last 1
}

if ($pullLarge) {
    Log "--- Pulling large-tier models (16 GB+) ---"
    foreach ($model in $LARGE_MODELS) {
        Log "  Pulling $model..."
        & ollama pull $model 2>&1 | Select-Object -Last 1
    }
}

Log "  Installed models:"
& ollama list 2>&1 | Select-Object -Skip 1 | ForEach-Object { Log "    $_" }

# ============================================================
# 4. Clone repo + Docker
# ============================================================
Log "--- Step 4/6: PicoCluster Claw repo + Docker ---"

if (-not (Test-Path "$INSTALL_DIR\.git")) {
    & git clone --depth 1 https://github.com/picocluster/PicoCluster-Claw.git $INSTALL_DIR
    Log "  Repo cloned"
} else {
    Push-Location $INSTALL_DIR
    & git pull --ff-only 2>&1 | Select-Object -Last 3
    Pop-Location
    Log "  Repo updated"
}

# Write .env
@"
CRUSH_IP=127.0.0.1
DEFAULT_MODEL=$DefaultModel
OPENCLAW_TOKEN=$OPENCLAW_TOKEN
"@ | Set-Content "$INSTALL_DIR\.env" -Encoding UTF8

Push-Location $INSTALL_DIR

Log "  Pulling ThreadWeaver image from GHCR..."
& docker compose -f docker-compose.yml -f docker-compose.windows.yml pull threadweaver 2>&1 | Select-Object -Last 5

Log "  Building local containers..."
& docker compose -f docker-compose.yml -f docker-compose.windows.yml build openclaw portal 2>&1 | Select-Object -Last 5

Log "  Starting containers..."
& docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d threadweaver openclaw portal 2>&1 | Select-Object -Last 10

# Wait for ThreadWeaver frontend
Log "  Waiting for services..."
$twReady = Wait-Url "http://127.0.0.1:5173/" -attempts 30 -delay 3
if ($twReady) { Log "  ThreadWeaver ready" }
else { Log "  WARNING: ThreadWeaver did not respond in time — check docker logs" }

Pop-Location

# ============================================================
# 5. User scripts
# ============================================================
Log "--- Step 5/6: User scripts ---"

$USER_BIN = "$env:USERPROFILE\bin"
if (-not (Test-Path $USER_BIN)) { New-Item -ItemType Directory -Path $USER_BIN | Out-Null }

if (Test-Path "$INSTALL_DIR\scripts\user-bin\windows") {
    Copy-Item "$INSTALL_DIR\scripts\user-bin\windows\*" $USER_BIN -Force
    Log "  Installed Windows scripts"
}

# Add ~/bin to user PATH if not present
$userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($userPath -notlike "*$USER_BIN*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$USER_BIN;$userPath", "User")
    Log "  Added $USER_BIN to user PATH (takes effect in new terminals)"
}

# ============================================================
# 6. Verify
# ============================================================
Log "--- Step 6/6: Verify ---"

Log "  Docker containers:"
& docker ps --format "    {{.Names}}: {{.Status}}"

Log ""
$TW_OK = if (Wait-Url "http://127.0.0.1:5173/"    -attempts 1 -delay 0) { "OK" } else { "FAIL" }
$OC_OK = if (Wait-Url "http://127.0.0.1:18789/__openclaw__/health" -attempts 1 -delay 0) { "OK" } else { "FAIL" }
$OL_OK = if (Wait-Url "http://localhost:11434/api/tags" -attempts 1 -delay 0) { "OK" } else { "FAIL" }
$PT_OK = if (Wait-Url "http://localhost:80/"        -attempts 1 -delay 0) { "OK" } else { "FAIL" }

Log "  ThreadWeaver: $TW_OK"
Log "  OpenClaw:     $OC_OK"
Log "  Ollama:       $OL_OK"
Log "  Portal:       $PT_OK"

try {
    $tools = Invoke-RestMethod "http://127.0.0.1:18789/__openclaw__/tools" -ErrorAction Stop
    Log "  MCP Tools:    $($tools.Count)"
} catch {
    Log "  MCP Tools:    (unavailable)"
}

Log ""
Log "============================================"
Log "  PicoCluster Claw — Windows Solo Install Complete"
Log "============================================"
Log ""
Log "  ThreadWeaver:  http://localhost:5173"
Log "  OpenClaw:      http://localhost:18789"
Log "  Portal:        http://localhost/"
Log "  Ollama:        http://localhost:11434"
Log ""
Log "  Docker commands (from $INSTALL_DIR):"
Log "    docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d"
Log "    docker compose -f docker-compose.yml -f docker-compose.windows.yml down"
Log "    docker compose logs -f"
Log ""
Log "  Manage models:"
Log "    ollama list              # Show installed models"
Log "    ollama pull <model>      # Download a model"
Log "    ollama rm <model>        # Remove a model"
Log "============================================"
