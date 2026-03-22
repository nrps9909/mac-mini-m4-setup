# OpenClaw + LINE Bot Interactive Setup (Mac Mini M4 Pro)

You are helping set up OpenClaw + LINE Bot on a fresh Mac Mini M4 Pro.
The base install script (`install-mac.sh`) has already been run.
Guide the user through each phase interactively, verifying each step before proceeding.

---

## Phase 1: Verify install.sh Results

Check that all prerequisites from `install-mac.sh` are working:

```bash
# Check all installed tools
node -v
ollama --version
pm2 -v
cloudflared --version
docker info

# Check Ollama models
ollama list
# Should show qwen3.5:9b and qwen3.5:4b

# Check Ollama API
curl -s http://localhost:11434/api/tags | jq '.models[].name'

# Check SearXNG
curl -s http://localhost:8888/healthz

# Check Ollama environment
echo "NUM_PARALLEL=$OLLAMA_NUM_PARALLEL"
echo "MAX_LOADED=$OLLAMA_MAX_LOADED_MODELS"
echo "KEEP_ALIVE=$OLLAMA_KEEP_ALIVE"
echo "FLASH_ATTN=$OLLAMA_FLASH_ATTENTION"
echo "KV_CACHE=$OLLAMA_KV_CACHE_TYPE"
```

If any check fails, fix it before proceeding. Common issues:
- Ollama not running: `open -a Ollama`
- Docker not running: `open -a Docker`
- SearXNG not started: `docker start searxng`

---

## Phase 2: OpenClaw Onboard

Run the OpenClaw onboarding wizard:

```bash
openclaw onboard
```

This is interactive. The user needs to provide:
- Anthropic API Key
- Choose model (claude-opus-4-6 recommended)
- Gateway password (auto-generated is fine, note it down)

After onboard completes, verify:
```bash
openclaw doctor
```

The onboard wizard may overwrite `openclaw.json`. If it does, restore the template settings:
- Verify `browser.executablePath` is `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
- Verify `browser.noSandbox` is NOT present (macOS doesn't need it)
- Verify `workspace` path uses `/Users/USERNAME/...` (not `/home/`)
- Verify `plugins.entries.openclaw-searxng` is configured with `baseUrl: "http://127.0.0.1:8888"`

---

## Phase 3: Fill In Secrets

Edit `~/.openclaw/.env` with real values:

```bash
# Open in editor
nano ~/.openclaw/.env
```

Required values:
1. `ANTHROPIC_API_KEY` - From https://console.anthropic.com/
2. `OPENCLAW_GATEWAY_PASSWORD` - Generated during onboard, or create: `uuidgen`
3. `HOOKS_SECRET` - Generate: `uuidgen`

Optional (fill later if needed):
- `TELEGRAM_BOT_TOKEN` - From @BotFather
- `TELEGRAM_CHAT_ID` - Your Telegram user ID
- `GEMINI_API_KEY` - For web search fallback
- `LINE_CHANNEL_SECRET` and `LINE_CHANNEL_ACCESS_TOKEN` - Phase 4

Source the env file:
```bash
source ~/.openclaw/.env
```

Add to shell profile so it loads automatically:
```bash
# Add to ~/.zshrc if not already there
echo '[ -f ~/.openclaw/.env ] && source ~/.openclaw/.env' >> ~/.zshrc
```

---

## Phase 4: Create LINE Bot

Guide the user through LINE Developers Console:

1. Go to https://developers.line.biz/
2. Log in with LINE account (or create one)
3. Create a new Provider (or use existing)
4. Create a new **Messaging API** channel:
   - Channel name: (user's choice)
   - Channel description: (user's choice)
   - Category: appropriate category
   - Subcategory: appropriate subcategory
5. In the channel settings, note down:
   - **Channel Secret** (Basic settings tab)
   - **Channel Access Token** (Messaging API tab > Issue)

Update `~/.openclaw/.env`:
```bash
LINE_CHANNEL_SECRET=<paste channel secret>
LINE_CHANNEL_ACCESS_TOKEN=<paste channel access token>
```

Re-source:
```bash
source ~/.openclaw/.env
```

---

## Phase 5: Cloudflare Tunnel

The user needs a Cloudflare account with a domain (using jesse-chen.com or similar).

1. Login to Cloudflare:
```bash
cloudflared tunnel login
# Opens browser for authentication
```

2. Create tunnel:
```bash
cloudflared tunnel create line-bot
# Note the tunnel UUID printed
```

3. Configure tunnel routing:
```bash
TUNNEL_UUID=$(cloudflared tunnel list | grep line-bot | awk '{print $1}')
```

4. Create tunnel config:
```bash
mkdir -p ~/.cloudflared
cat > ~/.cloudflared/config.yml << EOF
tunnel: $TUNNEL_UUID
credentials-file: $HOME/.cloudflared/$TUNNEL_UUID.json

ingress:
  - hostname: SUBDOMAIN.jesse-chen.com
    service: http://localhost:8787
  - service: http_status:404
EOF
```

Ask the user what subdomain they want (e.g., `linebot.jesse-chen.com`, `ai.jesse-chen.com`).

5. Create DNS route:
```bash
cloudflared tunnel route dns line-bot SUBDOMAIN.jesse-chen.com
```

6. Install as service (launchd):
```bash
cloudflared service install
```

7. Verify tunnel is running:
```bash
cloudflared tunnel info line-bot
# Check in Cloudflare Dashboard > Zero Trust > Tunnels
```

---

## Phase 6: Configure and Start LINE Webhook Proxy

1. Verify the proxy script is deployed:
```bash
ls -la ~/.openclaw/scripts/line-webhook-proxy.js
```

2. If the user wants custom trigger names for group chats, edit the file:
```bash
nano ~/.openclaw/scripts/line-webhook-proxy.js
```
Find `BOT_TRIGGER_NAMES = []` and add names. Example:
```javascript
const BOT_TRIGGER_NAMES = ["MyBot", "AI"];
```

3. Test the proxy manually first:
```bash
source ~/.openclaw/.env
GATEWAY_PASSWORD=$OPENCLAW_GATEWAY_PASSWORD node ~/.openclaw/scripts/line-webhook-proxy.js
```
In another terminal: `curl http://localhost:8787/health` should return `{"status":"ok",...}`

Stop the manual test (Ctrl+C) before proceeding to pm2.

---

## Phase 7: Start All Services with pm2

1. Source environment:
```bash
source ~/.openclaw/.env
```

2. Start services:
```bash
cd ~/.openclaw
pm2 start ecosystem.config.js
```

3. Verify both services are running:
```bash
pm2 status
# Should show:
# openclaw-gateway    online
# line-webhook-proxy  online
```

4. Check logs for errors:
```bash
pm2 logs --lines 20
```

5. Save pm2 process list (so it auto-restarts on reboot):
```bash
pm2 save
```

6. Verify services are responding:
```bash
# OpenClaw Gateway
curl -s http://localhost:18789 | head -5

# LINE Webhook Proxy
curl -s http://localhost:8787/health

# SearXNG
curl -s http://localhost:8888/healthz

# Ollama
curl -s http://localhost:11434/api/tags | jq '.models[].name'
```

---

## Phase 8: Configure LINE Webhook URL

1. Go back to LINE Developers Console
2. Navigate to your channel > Messaging API tab
3. Set Webhook URL to:
   ```
   https://SUBDOMAIN.jesse-chen.com/line/webhook
   ```
   (Use the subdomain configured in Phase 5)

4. Enable "Use webhook" toggle

5. Click "Verify" button in LINE Console
   - Should show "Success"
   - Check `pm2 logs line-webhook-proxy --lines 5` for the verification request

6. Disable "Auto-reply messages" and "Greeting messages" in LINE Console
   (These interfere with the AI bot)

---

## Phase 9: Create Your Bot's Identity

The user needs to create their own bot personality. Create the following files in `~/.openclaw/workspace/`:

```bash
mkdir -p ~/.openclaw/workspace
```

Guide the user to create:

1. **SOUL.md** - The bot's core personality and values
   - What persona does the bot have?
   - What tone and style?
   - What are its core principles?

2. **IDENTITY.md** - The bot's self-description
   - Name and role
   - Background story (if any)
   - How it introduces itself

3. **USER.md** - Information about the user/owner
   - Who is the owner?
   - What context should the bot know about?

4. **AGENTS.md** - Agent behavior guidelines
   - How should the bot handle different types of requests?
   - Any special behaviors for group vs DM?

These files are entirely up to the user. Ask them what kind of bot personality they want and help them write these files.

---

## Phase 10: End-to-End Verification

Run through the complete verification checklist:

```bash
echo "=== Service Status ==="
pm2 status

echo ""
echo "=== Ollama ==="
curl -s http://localhost:11434/api/tags | jq '.models[].name'

echo ""
echo "=== OpenClaw Gateway ==="
curl -s http://localhost:18789 | head -3

echo ""
echo "=== LINE Webhook Proxy ==="
curl -s http://localhost:8787/health

echo ""
echo "=== SearXNG ==="
curl -s http://localhost:8888/healthz | head -3

echo ""
echo "=== Cloudflare Tunnel ==="
cloudflared tunnel info line-bot 2>/dev/null | head -5

echo ""
echo "=== Cron Jobs ==="
crontab -l | grep -E "ai-(watchdog|auto-update)"

echo ""
echo "=== External Access ==="
curl -s https://SUBDOMAIN.jesse-chen.com/health
```

Final test:
1. Open LINE app on phone
2. Add the bot as friend (scan QR code from LINE Developers Console)
3. Send a test message like "Hello"
4. Should receive an AI-generated reply within 30-60 seconds

If the reply comes through: setup is complete!

If not, debug in order:
```bash
# Check proxy received the webhook
pm2 logs line-webhook-proxy --lines 20

# Check gateway is processing
pm2 logs openclaw-gateway --lines 20

# Check tunnel is routing
cloudflared tunnel info line-bot

# Check Ollama is responding
curl -s http://localhost:11434/api/generate -d '{"model":"qwen3.5:4b","prompt":"hi","stream":false}' | jq '.response'
```

---

## Post-Setup Reminders

- **Prevent sleep**: System Settings > Energy Saver > Prevent automatic sleeping when display is off
- **Docker Desktop memory**: Settings > Resources > Memory limit: 2GB
- **pm2 logs**: `pm2 logs` to monitor, `pm2 flush` to clear old logs
- **Restart all**: `pm2 restart all`
- **Stop all**: `pm2 stop all`
- **Update OpenClaw**: `npm install -g openclaw@latest && pm2 restart openclaw-gateway`
