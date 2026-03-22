# OpenClaw + LINE Bot -- Mac Mini M4 Pro 安裝手冊

## 系統需求

| 項目 | 需求 |
|------|------|
| 硬體 | Mac Mini M4 Pro (24GB Unified Memory / 512GB SSD) |
| macOS | 14 (Sonoma) 以上 |
| 網路 | 穩定的網路連線（安裝過程需下載約 15GB） |

## 架構圖

```
LINE App
  │
  ▼
Cloudflare Tunnel (*.jesse-chen.com)
  │
  ▼
LINE Webhook Proxy (:8787)  ──►  OpenClaw Gateway (:18789)
    [pm2]                            [pm2]
                                       │
                              ┌────────┼────────┐
                              ▼        ▼        ▼
                          Ollama    SearXNG   Claude API
                         (:11434)  (:8888)   (Anthropic)
                          [app]    [Docker]

服務管理：
  pm2        → OpenClaw Gateway, LINE Webhook Proxy
  launchd    → Ollama (app), Cloudflare Tunnel
  Docker     → SearXNG
  cron       → Health Watchdog (每 2 分鐘), Auto-Update (每週一 3AM)
```

## 安裝前準備

開始之前，請確認你有以下帳號和資訊：

1. **Apple ID** -- 已登入 Mac，用於 App Store / Xcode CLI tools
2. **Anthropic API Key** -- 從 https://console.anthropic.com/ 取得
3. **LINE Developer 帳號** -- https://developers.line.biz/ （用 LINE 帳號登入）
4. **Cloudflare 帳號** -- 擁有 jesse-chen.com（或其他域名）的管理權限
5. **Telegram Bot Token**（選填）-- 從 @BotFather 取得

## 記憶體分配預算 (24GB)

| 用途 | 預估 |
|------|------|
| macOS 系統 | ~5GB |
| Docker Desktop (SearXNG) | ~2GB |
| OpenClaw + LINE Proxy | ~0.5GB |
| qwen3.5:9b 模型 | ~6.6GB |
| qwen3.5:4b 模型 | ~3GB |
| KV Cache 餘量 | ~7GB |

## 三步驟安裝流程

### 步驟 1：執行安裝腳本

```bash
# 下載或複製整個 mac-mini-m4 資料夾到 Mac
# 開啟 Terminal，進入資料夾

cd ~/mac-mini-m4   # 或你放置的路徑
bash install-mac.sh
```

腳本會自動安裝：
- Homebrew + 基礎工具 (node, jq, git, python3)
- Ollama + M4 Pro 優化環境變數
- AI 模型 (qwen3.5:9b, qwen3.5:4b)
- Docker Desktop + SearXNG 容器
- OpenClaw
- pm2
- cloudflared
- 模板文件 + cron jobs

**注意**：安裝過程中可能需要輸入密碼，Docker Desktop 安裝後可能需要手動開啟一次完成初始設定。

### 步驟 2：Claude Code 互動設定

將 `claude-code-setup-prompt.md` 的內容貼入 Claude Code，依照 10 個 Phase 完成：

| Phase | 內容 | 需要的資訊 |
|-------|------|-----------|
| 1 | 驗證安裝結果 | 無 |
| 2 | OpenClaw onboard | Anthropic API Key |
| 3 | 填入 secrets | API keys |
| 4 | 建立 LINE Bot | LINE Developer Console 操作 |
| 5 | Cloudflare Tunnel | Cloudflare 帳號 + 選擇 subdomain |
| 6 | LINE Webhook Proxy 設定 | 自訂 Bot 觸發名稱（選填） |
| 7 | pm2 啟動所有服務 | 無 |
| 8 | LINE Webhook URL 設定 | LINE Developer Console 操作 |
| 9 | 建立 Bot 人設 | 你想要的 Bot 個性 |
| 10 | 端到端驗證 | LINE App 測試 |

### 步驟 3：驗證

在 LINE App 上加 Bot 為好友，發送測試訊息，確認收到 AI 回覆。

## 服務管理指令對照表

| 操作 | Linux (systemd) | macOS (pm2/brew) |
|------|-----------------|-------------------|
| 查看所有服務 | `systemctl status` | `pm2 status` |
| 重啟 OpenClaw | `systemctl --user restart openclaw-gateway` | `pm2 restart openclaw-gateway` |
| 重啟 LINE Proxy | `systemctl restart line-webhook-proxy` | `pm2 restart line-webhook-proxy` |
| 重啟 Ollama | `systemctl restart ollama` | `open -a Ollama`（或 `pkill -x Ollama; sleep 2; open -a Ollama`） |
| 重啟 Cloudflare Tunnel | `systemctl restart cloudflared-tunnel` | `launchctl load ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist` |
| 重啟 SearXNG | `docker restart searxng` | `docker restart searxng` |
| 查看 logs | `journalctl -u ...` | `pm2 logs` |
| 重啟全部 | `systemctl restart ...` (逐一) | `pm2 restart all` |
| 開機自啟 | `systemctl enable` | `pm2 startup` + `pm2 save` |

## 故障排除

### Ollama 沒有回應

```bash
# 確認 Ollama 正在執行
pgrep ollama

# 如果沒有，開啟 Ollama app
open -a Ollama

# 檢查 API
curl http://localhost:11434/api/tags

# 如果 Flash Attention 有問題，停用它：
# 編輯 ~/.zshrc，將 OLLAMA_FLASH_ATTENTION=1 改為 0
# 然後重啟 Ollama
```

### LINE 訊息沒有回覆

```bash
# 1. 檢查 Cloudflare Tunnel
cloudflared tunnel info line-bot

# 2. 檢查 LINE Proxy
pm2 logs line-webhook-proxy --lines 30

# 3. 檢查 OpenClaw Gateway
pm2 logs openclaw-gateway --lines 30

# 4. 直接測試 Gateway API
curl -X POST http://localhost:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENCLAW_GATEWAY_PASSWORD" \
  -H "X-Session-Key: test" \
  -d '{"model":"default","messages":[{"role":"user","content":"hello"}]}'
```

### SearXNG 無法搜尋

```bash
# 檢查容器狀態
docker ps | grep searxng

# 重啟容器
docker restart searxng

# 檢查健康狀態
curl http://localhost:8888/healthz
```

### pm2 服務異常

```bash
# 查看詳細狀態
pm2 describe openclaw-gateway
pm2 describe line-webhook-proxy

# 查看錯誤日誌
pm2 logs --err --lines 50

# 完全重啟
pm2 delete all
source ~/.openclaw/.env
cd ~/.openclaw && pm2 start ecosystem.config.js
pm2 save
```

### Docker Desktop 記憶體占用過高

Docker Desktop > Settings > Resources > Memory limit 設為 2GB。
SearXNG 本身只需要約 200MB，2GB 足夠。

## macOS 特殊注意事項

### 防止休眠（重要！）

Mac Mini 作為伺服器必須保持常開：

1. **System Settings > Energy Saver**:
   - Prevent automatic sleeping when the display is off: **ON**
   - Wake for network access: **ON**
   - Start up automatically after a power failure: **ON**

2. 或使用命令列：
   ```bash
   # 持續防止休眠（在背景執行）
   caffeinate -s &
   ```

### 自動登入

System Settings > Users & Groups > Automatic Login > 選擇用戶

這確保重開機後 pm2 和其他使用者層級服務能自動啟動。

### macOS 更新

macOS 更新可能重啟系統。更新後確認：
```bash
pm2 status        # 檢查 pm2 服務
docker ps          # 檢查 Docker 容器
ollama list        # 檢查 Ollama
```

## 目錄結構

```
~/.openclaw/
├── openclaw.json              # OpenClaw 主設定
├── .env                       # 環境變數（secrets）
├── ecosystem.config.js        # pm2 設定
├── workspace/                 # OpenClaw workspace
│   ├── SOUL.md               # Bot 人設
│   ├── IDENTITY.md           # Bot 身分
│   ├── USER.md               # 用戶資訊
│   └── AGENTS.md             # Agent 行為準則
└── scripts/
    ├── line-webhook-proxy.js  # LINE Webhook 代理
    ├── ai-watchdog.sh         # 健康檢查腳本
    └── ai-auto-update.sh      # 自動更新腳本

~/.cloudflared/
├── config.yml                 # Tunnel 設定
└── <tunnel-uuid>.json         # Tunnel 憑證

~/logs/
├── ai-watchdog.log            # 健康檢查日誌
└── ai-auto-update.log         # 自動更新日誌
```
