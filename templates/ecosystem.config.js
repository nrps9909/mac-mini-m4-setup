// pm2 ecosystem configuration for OpenClaw + LINE Bot
// Usage: pm2 start ecosystem.config.js
//
// All secrets are read from ~/.openclaw/.env
// Run `source ~/.openclaw/.env` before pm2 start, or use dotenv in env_production

const path = require("path");
const os = require("os");

const OPENCLAW_HOME = path.join(os.homedir(), ".openclaw");

module.exports = {
  apps: [
    {
      name: "openclaw-gateway",
      script: "openclaw",
      args: "gateway --port 18789",
      cwd: OPENCLAW_HOME,
      interpreter: "none",  // openclaw is a standalone CLI
      env: {
        ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY || "",
        OLLAMA_BASE_URL: process.env.OLLAMA_BASE_URL || "http://127.0.0.1:11434",
        GEMINI_API_KEY: process.env.GEMINI_API_KEY || "",
        OPENCLAW_GATEWAY_PASSWORD: process.env.OPENCLAW_GATEWAY_PASSWORD || "",
        HOOKS_SECRET: process.env.HOOKS_SECRET || "",
        TELEGRAM_BOT_TOKEN: process.env.TELEGRAM_BOT_TOKEN || "",
        LINE_CHANNEL_ACCESS_TOKEN: process.env.LINE_CHANNEL_ACCESS_TOKEN || "",
        LINE_CHANNEL_SECRET: process.env.LINE_CHANNEL_SECRET || "",
      },
      restart_delay: 5000,
      max_restarts: 10,
      autorestart: true,
      watch: false,
    },
    {
      name: "line-webhook-proxy",
      script: path.join(OPENCLAW_HOME, "scripts", "line-webhook-proxy.js"),
      cwd: OPENCLAW_HOME,
      env: {
        LINE_CHANNEL_SECRET: process.env.LINE_CHANNEL_SECRET || "",
        LINE_CHANNEL_ACCESS_TOKEN: process.env.LINE_CHANNEL_ACCESS_TOKEN || "",
        PROXY_PORT: "8787",
        GATEWAY_URL: "http://127.0.0.1:18789",
        GATEWAY_PASSWORD: process.env.OPENCLAW_GATEWAY_PASSWORD || "",
      },
      restart_delay: 3000,
      max_restarts: 10,
      autorestart: true,
      watch: false,
    },
  ],
};
