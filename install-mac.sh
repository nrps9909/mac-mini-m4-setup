#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# install-mac.sh — OpenClaw + LINE Bot Setup for Mac Mini M4 Pro
# Target: M4 Pro (24GB Unified Memory / 512GB SSD)
# Run with: bash install-mac.sh
# Idempotent: safe to re-run
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
OPENCLAW_HOME="$HOME/.openclaw"
SCRIPTS_DIR="$OPENCLAW_HOME/scripts"
LOGS_DIR="$HOME/logs"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw + LINE Bot Setup (Mac Mini M4 Pro / 24GB RAM)        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Pre-flight checks
if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: This script is designed for macOS only."
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "WARNING: Expected Apple Silicon (arm64), got $(uname -m). Continuing anyway..."
fi

if [ ! -d "$TEMPLATES_DIR" ]; then
    echo "ERROR: templates/ directory not found at $TEMPLATES_DIR"
    echo "Make sure you run this script from the directory containing templates/"
    exit 1
fi

mkdir -p "$OPENCLAW_HOME" "$SCRIPTS_DIR" "$LOGS_DIR"

# ─── 1. Homebrew + basic tools ────────────────────────────────────
echo "[1/9] Homebrew + basic tools..."
if ! command -v brew &>/dev/null; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for this session
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    echo "  Skip: Homebrew already installed"
fi

# Ensure brew is in PATH
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew install node jq git python3 2>/dev/null || true
echo "  Node.js: $(node -v 2>/dev/null || echo 'not found')"
echo "  Done: basic tools"

# ─── 2. Ollama ────────────────────────────────────────────────────
echo "[2/9] Installing Ollama..."
if ! command -v ollama &>/dev/null; then
    brew install --cask ollama 2>/dev/null || brew install --cask ollama-app
    echo "  Done: Ollama installed"
else
    echo "  Skip: Ollama already installed ($(ollama --version 2>/dev/null || echo 'unknown'))"
fi

# Configure Ollama environment for M4 Pro 24GB
echo "  Configuring Ollama environment for M4 Pro 24GB..."

# Set environment variables via launchctl (persists across reboots for GUI apps)
launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
launchctl setenv OLLAMA_NUM_PARALLEL "2"
launchctl setenv OLLAMA_MAX_LOADED_MODELS "2"
launchctl setenv OLLAMA_KEEP_ALIVE "30m"
launchctl setenv OLLAMA_FLASH_ATTENTION "1"
launchctl setenv OLLAMA_KV_CACHE_TYPE "q8_0"
launchctl setenv OLLAMA_MAX_QUEUE "256"

# Also export for current shell session
export OLLAMA_HOST="0.0.0.0:11434"
export OLLAMA_NUM_PARALLEL=2
export OLLAMA_MAX_LOADED_MODELS=2
export OLLAMA_KEEP_ALIVE=30m
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_MAX_QUEUE=256

# Add to shell profile for future terminal sessions
SHELL_PROFILE="$HOME/.zshrc"
if ! grep -q "OLLAMA_NUM_PARALLEL" "$SHELL_PROFILE" 2>/dev/null; then
    cat >> "$SHELL_PROFILE" << 'OLLAMA_ENV'

# --- Ollama M4 Pro 24GB optimization ---
export OLLAMA_HOST="0.0.0.0:11434"
export OLLAMA_NUM_PARALLEL=2
export OLLAMA_MAX_LOADED_MODELS=2
export OLLAMA_KEEP_ALIVE=30m
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_MAX_QUEUE=256
OLLAMA_ENV
    echo "  Added Ollama env vars to $SHELL_PROFILE"
fi

# ┌────────────────────────────────────────────────────────────┐
# │ M4 Pro 24GB optimization notes:                            │
# │                                                            │
# │ NUM_PARALLEL=2    24GB supports 2 parallel KV caches       │
# │ MAX_LOADED_MODELS=2  Keep 9b+4b loaded, zero switch delay  │
# │ KEEP_ALIVE=30m    Shorter than 64GB, conserve memory       │
# │ FLASH_ATTENTION=1  M4 Pro Metal native support             │
# │ KV_CACHE_TYPE=q8_0  50% KV cache memory savings           │
# │ MAX_QUEUE=256      Handle burst requests                   │
# └────────────────────────────────────────────────────────────┘

# Start Ollama (it runs as a macOS app via launchd)
echo "  Starting Ollama..."
open -a Ollama 2>/dev/null || true

# Wait for Ollama to be ready
echo "  Waiting for Ollama API..."
for i in $(seq 1 30); do
    if curl -sf --max-time 2 http://localhost:11434/api/tags &>/dev/null; then
        echo "  Ollama API is ready"
        break
    fi
    [ "$i" -eq 30 ] && echo "  WARNING: Ollama not responding after 60s. Open Ollama.app manually."
    sleep 2
done
echo "  Done: Ollama configured"

# ─── 3. Pull models ───────────────────────────────────────────────
echo "[3/9] Pulling AI models (this will take a while on first run)..."
echo "  Pulling qwen3.5:9b (main model, ~6.6GB)..."
ollama pull qwen3.5:9b
echo "  Pulling qwen3.5:4b (fast/heartbeat, ~3GB)..."
ollama pull qwen3.5:4b
echo "  Done: Models pulled"
ollama list

# ─── 4. Docker Desktop ────────────────────────────────────────────
echo "[4/9] Installing Docker Desktop..."
if ! command -v docker &>/dev/null; then
    brew install --cask docker
    echo "  Done: Docker Desktop installed"
    echo "  NOTE: Open Docker Desktop manually and complete first-run setup."
    echo "  Then re-run this script to continue with SearXNG setup."
else
    echo "  Skip: Docker already installed"
fi

# Wait for Docker to be ready (in case it was just installed or starting)
if command -v docker &>/dev/null; then
    echo "  Checking Docker daemon..."
    for i in $(seq 1 15); do
        if docker info &>/dev/null; then
            echo "  Docker daemon is ready"
            break
        fi
        if [ "$i" -eq 1 ]; then
            echo "  Waiting for Docker Desktop to start..."
            open -a Docker 2>/dev/null || true
        fi
        [ "$i" -eq 15 ] && echo "  WARNING: Docker not responding. Open Docker Desktop manually."
        sleep 4
    done
fi

# ─── 5. SearXNG Docker container ──────────────────────────────────
echo "[5/9] Setting up SearXNG search engine..."
if docker info &>/dev/null; then
    if docker ps -a --format '{{.Names}}' | grep -q '^searxng$'; then
        echo "  Skip: SearXNG container already exists"
        # Make sure it's running
        docker start searxng 2>/dev/null || true
    else
        docker run -d \
            --name searxng \
            --restart always \
            -p 8888:8080 \
            -e SEARXNG_BASE_URL=http://localhost:8888/ \
            searxng/searxng:latest
        echo "  Done: SearXNG running on port 8888"
    fi
else
    echo "  SKIP: Docker not available, SearXNG setup deferred"
fi

# ─── 6. OpenClaw ──────────────────────────────────────────────────
echo "[6/9] Installing OpenClaw..."
if ! command -v openclaw &>/dev/null; then
    npm install -g openclaw@latest
    echo "  Done: OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"
else
    echo "  Skip: OpenClaw already installed ($(openclaw --version 2>/dev/null || echo 'unknown'))"
fi

# ─── 7. pm2 ───────────────────────────────────────────────────────
echo "[7/9] Installing pm2..."
if ! command -v pm2 &>/dev/null; then
    npm install -g pm2
    echo "  Done: pm2 installed"
else
    echo "  Skip: pm2 already installed"
fi

# Setup pm2 startup (auto-start on boot)
echo "  Configuring pm2 startup..."
mkdir -p "$HOME/Library/LaunchAgents"
pm2 startup 2>/dev/null || true

# ─── 8. cloudflared ───────────────────────────────────────────────
echo "[8/9] Installing cloudflared..."
if ! command -v cloudflared &>/dev/null; then
    brew tap cloudflare/cloudflare 2>/dev/null || true
    brew install cloudflare/cloudflare/cloudflared 2>/dev/null || brew install cloudflared
    echo "  Done: cloudflared installed"
else
    echo "  Skip: cloudflared already installed"
fi

# ─── 9. Deploy templates + cron jobs ──────────────────────────────
echo "[9/9] Deploying template files + cron jobs..."

# Copy templates
cp "$TEMPLATES_DIR/line-webhook-proxy.js" "$SCRIPTS_DIR/line-webhook-proxy.js"
cp "$TEMPLATES_DIR/ecosystem.config.js" "$OPENCLAW_HOME/ecosystem.config.js"
cp "$TEMPLATES_DIR/ai-watchdog.sh" "$OPENCLAW_HOME/scripts/ai-watchdog.sh"
cp "$TEMPLATES_DIR/ai-auto-update.sh" "$OPENCLAW_HOME/scripts/ai-auto-update.sh"
chmod +x "$SCRIPTS_DIR/ai-watchdog.sh" "$SCRIPTS_DIR/ai-auto-update.sh"

# Copy env.example if .env doesn't exist yet
if [ ! -f "$OPENCLAW_HOME/.env" ]; then
    cp "$TEMPLATES_DIR/env.example" "$OPENCLAW_HOME/.env"
    echo "  Created $OPENCLAW_HOME/.env (fill in real values)"
fi

# Copy openclaw.json template if not already configured
if [ ! -f "$OPENCLAW_HOME/openclaw.json" ]; then
    # Replace USERNAME placeholder with actual username
    sed "s/USERNAME/$(whoami)/g" "$TEMPLATES_DIR/openclaw.json" > "$OPENCLAW_HOME/openclaw.json"
    echo "  Created $OPENCLAW_HOME/openclaw.json"
else
    echo "  Skip: openclaw.json already exists"
fi

# Create workspace directory
mkdir -p "$OPENCLAW_HOME/workspace"

# Setup cron jobs (macOS crontab)
WATCHDOG_CMD="$SCRIPTS_DIR/ai-watchdog.sh"
UPDATE_CMD="$SCRIPTS_DIR/ai-auto-update.sh"

# Build new crontab preserving existing non-AI entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v "ai-watchdog" | grep -v "ai-auto-update" || true)
NEW_CRON="$EXISTING_CRON
# AI Stack Health Watchdog (every 2 minutes)
*/2 * * * * $WATCHDOG_CMD
# AI Stack Auto-Update (weekly Monday 3:00 AM)
0 3 * * 1 $UPDATE_CMD"

echo "$NEW_CRON" | crontab -
echo "  Cron jobs installed (watchdog: every 2min, auto-update: Mon 3AM)"
echo "  NOTE: On macOS Sequoia, cron requires Full Disk Access."
echo "  Go to: System Settings > Privacy & Security > Full Disk Access > add /usr/sbin/cron"

echo "  Done: templates deployed"

# ═══════════════════════════════════════════════════════════════════
# Verification
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Setup Complete -- Verification                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

echo "=== System ==="
echo "  macOS: $(sw_vers -productVersion)"
echo "  Chip:  $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
echo "  RAM:   $(( $(sysctl -n hw.memsize) / 1073741824 ))GB"
echo ""

echo "=== Ollama ==="
if curl -sf --max-time 5 http://localhost:11434/api/tags &>/dev/null; then
    echo "  Status: running"
else
    echo "  Status: NOT RUNNING (open Ollama.app)"
fi
echo ""

echo "=== Models ==="
ollama list 2>/dev/null || echo "  (ollama not responding)"
echo ""

echo "=== Node.js + Tools ==="
echo "  node:      $(node -v 2>/dev/null || echo 'not found')"
echo "  openclaw:  $(openclaw --version 2>/dev/null || echo 'not found')"
echo "  pm2:       $(pm2 -v 2>/dev/null || echo 'not found')"
echo "  cloudflared: $(cloudflared --version 2>/dev/null | head -1 || echo 'not found')"
echo ""

echo "=== Docker ==="
if docker info &>/dev/null; then
    echo "  Status: running"
    docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true
else
    echo "  Status: NOT RUNNING (open Docker Desktop)"
fi
echo ""

echo "=== Cron Jobs ==="
crontab -l 2>/dev/null | grep -E "ai-(watchdog|auto-update)" || echo "  (none found)"
echo ""

echo "=== Deployed Files ==="
for f in "$SCRIPTS_DIR/line-webhook-proxy.js" "$OPENCLAW_HOME/ecosystem.config.js" "$OPENCLAW_HOME/.env" "$OPENCLAW_HOME/openclaw.json"; do
    if [ -f "$f" ]; then
        echo "  OK: $f"
    else
        echo "  MISSING: $f"
    fi
done
echo ""

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Next Steps                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  1. Prevent Mac from sleeping:"
echo "     System Settings > Energy Saver > Prevent automatic sleeping"
echo "     (Or run: caffeinate -s &)"
echo ""
echo "  2. Docker Desktop memory limit:"
echo "     Docker Desktop > Settings > Resources > Memory: 2GB"
echo ""
echo "  3. Run Claude Code with the setup prompt:"
echo "     Copy claude-code-setup-prompt.md content into Claude Code"
echo "     for interactive configuration of:"
echo "     - openclaw onboard"
echo "     - LINE Bot secrets"
echo "     - Cloudflare Tunnel"
echo "     - pm2 services"
echo "     - End-to-end verification"
echo ""
