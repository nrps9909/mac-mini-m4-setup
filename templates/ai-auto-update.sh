#!/bin/bash
# ============================================================
# AI Stack Auto-Updater (macOS) -- runs weekly Monday 3:00 AM
# Updates: Ollama models + Ollama engine + OpenClaw + Skills
# ============================================================
set -o pipefail

LOG="$HOME/logs/ai-auto-update.log"
LOCK="/tmp/ai-auto-update.lock"
OLLAMA_HOST="http://localhost:11434"

mkdir -p "$(dirname "$LOG")"

# --- Prevent concurrent runs ---
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        echo "$(date '+%F %T') [SKIP] Another update is running (PID $pid)" >> "$LOG"
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

log() { echo "$(date '+%F %T') $1" >> "$LOG"; }

notify_error() {
    local msg="$1"
    # Send failure notification via Telegram using OpenClaw
    openclaw agent \
        --message "Warning: Auto-Update failed: $msg" \
        --channel telegram --deliver --timeout 30 \
        2>/dev/null || true
}

log "========== Auto-Update Started =========="

# --- Log rotation (10MB max) ---
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$LOG" "$LOG.old"
    log "Log rotated"
fi

UPDATED_MODELS=0
ERRORS=0

# --- Record pre-update versions ---
log "Pre-update versions:"
log "  Ollama: $(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
log "  OpenClaw: $(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"

# ============================================================
# 1. Ollama model updates
# ============================================================
log "[1/4] Checking Ollama models..."

if curl -sf --max-time 10 "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
    for model in qwen3.5:9b qwen3.5:4b; do
        log "  Pulling $model..."
        OLD_DIGEST=$(curl -sf "$OLLAMA_HOST/api/tags" | python3 -c "
import sys, json
for m in json.load(sys.stdin).get('models',[]):
    if m['name']=='$model': print(m.get('digest','')[:12])
" 2>/dev/null)

        if ollama pull "$model" > /dev/null 2>&1; then
            NEW_DIGEST=$(curl -sf "$OLLAMA_HOST/api/tags" | python3 -c "
import sys, json
for m in json.load(sys.stdin).get('models',[]):
    if m['name']=='$model': print(m.get('digest','')[:12])
" 2>/dev/null)
            if [ "$OLD_DIGEST" != "$NEW_DIGEST" ]; then
                log "  $model updated ($OLD_DIGEST -> $NEW_DIGEST)"
                UPDATED_MODELS=$((UPDATED_MODELS + 1))
            else
                log "  $model already latest"
            fi
        else
            log "  $model pull failed"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    log "  Ollama not reachable, skipping model updates"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# 2. Ollama engine update
# ============================================================
log "[2/4] Updating Ollama engine..."

OLD_OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

if brew upgrade --cask ollama 2>/dev/null || brew upgrade --cask ollama-app 2>/dev/null; then
    NEW_OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    if [ "$OLD_OLLAMA_VER" != "$NEW_OLLAMA_VER" ]; then
        log "  Ollama updated ($OLD_OLLAMA_VER -> $NEW_OLLAMA_VER)"
    else
        log "  Ollama engine already latest ($OLD_OLLAMA_VER)"
    fi
else
    log "  Ollama brew upgrade returned non-zero (may already be latest)"
fi

# ============================================================
# 3. OpenClaw update
# ============================================================
log "[3/4] Updating OpenClaw..."

OLD_OC_VER=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

if npm install -g openclaw@latest > /dev/null 2>&1; then
    NEW_OC_VER=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    if [ "$OLD_OC_VER" != "$NEW_OC_VER" ]; then
        log "  OpenClaw updated ($OLD_OC_VER -> $NEW_OC_VER)"
        # Run doctor to fix any config migration issues
        openclaw doctor --fix > /dev/null 2>&1
        log "  Ran openclaw doctor --fix"
        # Restart gateway
        pm2 restart openclaw-gateway 2>/dev/null
        sleep 10
        log "  OpenClaw gateway restarted"
    else
        log "  OpenClaw already latest ($OLD_OC_VER)"
    fi
else
    log "  OpenClaw npm update failed"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# 4. Health verification after updates
# ============================================================
log "[4/4] Post-update health check..."

HEALTH_OK=true

# Check Ollama
if curl -sf --max-time 10 "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
    log "  Ollama: OK"
else
    log "  Ollama: FAILED"
    pkill -x Ollama 2>/dev/null; sleep 2; open -a Ollama
    HEALTH_OK=false
fi

# Check OpenClaw
if curl -sf --max-time 10 http://localhost:18789 > /dev/null 2>&1; then
    log "  OpenClaw: OK"
else
    log "  OpenClaw: FAILED"
    pm2 restart openclaw-gateway 2>/dev/null
    HEALTH_OK=false
fi

# Summary
log "========== Update Complete =========="
log "Models updated: $UPDATED_MODELS | Errors: $ERRORS | Health: $([ "$HEALTH_OK" = true ] && echo 'ALL OK' || echo 'ISSUES')"

if [ "$ERRORS" -gt 0 ] || [ "$HEALTH_OK" != true ]; then
    notify_error "Models updated: $UPDATED_MODELS | Errors: $ERRORS | Health: $([ "$HEALTH_OK" = true ] && echo 'ALL OK' || echo 'ISSUES')"
fi

log ""
