#!/bin/bash
# Health watchdog for macOS -- run via cron every 2 minutes
# Checks Ollama, OpenClaw Gateway, Cloudflare Tunnel, LINE Proxy, and SearXNG
# Restarts unhealthy services automatically

LOG="$HOME/logs/ai-watchdog.log"
mkdir -p "$(dirname "$LOG")"

# Rotate log if > 10MB
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$LOG" "$LOG.old"
fi

check_ollama() {
    if ! curl -sf --max-time 10 http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: Ollama is down, restarting" >> "$LOG"
        brew services restart ollama
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Ollama restarted" >> "$LOG"
    fi
}

check_openclaw() {
    if ! curl -sf --max-time 10 http://localhost:18789 > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: openclaw-gateway is down, restarting" >> "$LOG"
        pm2 restart openclaw-gateway
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: openclaw-gateway restarted" >> "$LOG"
    fi
}

check_line_proxy() {
    if ! curl -sf --max-time 10 http://localhost:8787/health > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: line-webhook-proxy is down, restarting" >> "$LOG"
        pm2 restart line-webhook-proxy
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: line-webhook-proxy restarted" >> "$LOG"
    fi
}

check_cloudflared() {
    if ! pgrep -x cloudflared > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: cloudflared is down, restarting" >> "$LOG"
        launchctl load ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist 2>/dev/null || \
            brew services restart cloudflared 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: cloudflared restarted" >> "$LOG"
    fi
}

check_searxng() {
    if ! curl -sf --max-time 10 "http://localhost:8888/healthz" > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: SearXNG is down, restarting container" >> "$LOG"
        docker restart searxng 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: SearXNG container restarted" >> "$LOG"
    fi
}

check_disk_space() {
    local usage
    usage=$(df / | awk 'NR==2{print int($5)}')
    if [ "$usage" -gt 90 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: Disk usage at ${usage}%!" >> "$LOG"
    fi
}

# Run all checks
check_ollama
check_openclaw
check_line_proxy
check_cloudflared
check_searxng
check_disk_space
