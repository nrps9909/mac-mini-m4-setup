#!/usr/bin/env node
/**
 * LINE Webhook Proxy -- Full handler
 *
 * Receives LINE webhooks, calls OpenClaw chat API for AI response,
 * and replies directly via LINE Messaging API.
 *
 * Env vars:
 *   LINE_CHANNEL_SECRET       - LINE channel secret
 *   LINE_CHANNEL_ACCESS_TOKEN - LINE channel access token
 *   PROXY_PORT                - Listen port (default: 8787)
 *   GATEWAY_URL               - OpenClaw gateway (default: http://127.0.0.1:18789)
 *   GATEWAY_PASSWORD          - Gateway password for chat API
 */
const http = require("node:http");
const https = require("node:https");
const crypto = require("node:crypto");

const LINE_SECRET = process.env.LINE_CHANNEL_SECRET || "";
const LINE_TOKEN = process.env.LINE_CHANNEL_ACCESS_TOKEN || "";
const PROXY_PORT = parseInt(process.env.PROXY_PORT || "8787", 10);
const GATEWAY_URL = process.env.GATEWAY_URL || "http://127.0.0.1:18789";
const GATEWAY_PASSWORD = process.env.GATEWAY_PASSWORD || "";

function ts() { return new Date().toISOString(); }

// ---------- Per-user request queue (prevents concurrent message stomping) ----------
const userQueues = new Map();

function enqueueForUser(userId, fn) {
  const prev = userQueues.get(userId) || Promise.resolve();
  const next = prev.then(fn, fn); // always chain, even on error
  userQueues.set(userId, next);
  next.finally(() => {
    // Clean up if this is still the tail
    if (userQueues.get(userId) === next) userQueues.delete(userId);
  });
  return next;
}

// ---------- LINE API helpers ----------

function validateSignature(body, signature) {
  const expected = crypto.createHmac("SHA256", LINE_SECRET).update(body).digest("base64");
  try {
    return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
  } catch { return false; }
}

function lineApiCall(url, payload) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${LINE_TOKEN}`,
        "Content-Length": Buffer.byteLength(payload),
      },
    }, (res) => {
      let data = "";
      res.on("data", (c) => data += c);
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(data);
        else reject(new Error(`LINE ${res.statusCode}: ${data}`));
      });
    });
    req.on("error", reject);
    req.end(payload);
  });
}

// Split long text into chunks that fit LINE's 5000 char limit
function splitText(text, limit = 5000) {
  if (text.length <= limit) return [text];
  const chunks = [];
  let remaining = text;
  while (remaining.length > 0) {
    if (remaining.length <= limit) {
      chunks.push(remaining);
      break;
    }
    const cut = remaining.slice(0, limit);
    // Try to cut at a natural break point
    const lastBreak = Math.max(
      cut.lastIndexOf("\n\n"),
      cut.lastIndexOf("\n"),
      cut.lastIndexOf("\u3002"),
      cut.lastIndexOf("\uff01"),
      cut.lastIndexOf("\uff1f"),
      cut.lastIndexOf(". "),
    );
    const splitAt = lastBreak > limit * 0.5 ? lastBreak + 1 : limit;
    chunks.push(remaining.slice(0, splitAt));
    remaining = remaining.slice(splitAt);
  }
  return chunks;
}

// Reply API (free, unlimited, but token expires in ~60s)
// LINE allows max 5 messages per reply call
function replyLine(replyToken, text) {
  const chunks = splitText(text, 5000).slice(0, 5);
  const payload = JSON.stringify({
    replyToken,
    messages: chunks.map(c => ({ type: "text", text: c })),
  });
  return lineApiCall("https://api.line.me/v2/bot/message/reply", payload);
}

// Push API (uses monthly quota on free plan)
// For push, send chunks as separate calls if > 5 messages needed
async function pushLine(userId, text) {
  const chunks = splitText(text, 5000);
  // Send in batches of 5 (LINE limit per push call)
  for (let i = 0; i < chunks.length; i += 5) {
    const batch = chunks.slice(i, i + 5);
    const payload = JSON.stringify({
      to: userId,
      messages: batch.map(c => ({ type: "text", text: c })),
    });
    await lineApiCall("https://api.line.me/v2/bot/message/push", payload);
  }
}

// Show loading animation (typing indicator)
function showLoadingAnimation(chatId, loadingSeconds = 60) {
  const payload = JSON.stringify({ chatId, loadingSeconds });
  return new Promise((resolve) => {
    const req = https.request("https://api.line.me/v2/bot/chat/loading/start", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${LINE_TOKEN}`,
        "Content-Length": Buffer.byteLength(payload),
      },
    }, (res) => {
      let data = "";
      res.on("data", (c) => data += c);
      res.on("end", () => resolve());
    });
    req.on("error", () => resolve());
    req.end(payload);
  });
}

// ---------- Text processing ----------

// Convert Markdown to clean LINE plain text
function mdToLine(text) {
  return text
    .replace(/^#{1,6}\s+(.+)$/gm, "\u3010$1\u3011")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/__(.+?)__/g, "$1")
    .replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, "$1")
    .replace(/(?<!_)_(?!_)(.+?)(?<!_)_(?!_)/g, "$1")
    .replace(/~~(.+?)~~/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/```[\s\S]*?```/g, (m) => m.replace(/```\w*\n?/g, "").replace(/```/g, "").trim())
    .replace(/^>\s+(.+)$/gm, "\u300c$1\u300d")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    .replace(/^[-*_]{3,}$/gm, "\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// ---------- Gateway API ----------

function chatComplete(userMessage, sessionKey) {
  const payload = JSON.stringify({
    model: "default",
    messages: [{ role: "user", content: userMessage }],
  });
  const url = new URL("/v1/chat/completions", GATEWAY_URL);
  return new Promise((resolve, reject) => {
    const req = http.request(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${GATEWAY_PASSWORD}`,
        "X-Session-Key": sessionKey,
        "Content-Length": Buffer.byteLength(payload),
      },
      timeout: 0,
    }, (res) => {
      let data = "";
      res.on("data", (c) => data += c);
      res.on("end", () => {
        if (res.statusCode === 200) {
          try {
            const parsed = JSON.parse(data);
            const text = parsed.choices?.[0]?.message?.content || "";
            resolve(text);
          } catch { resolve(""); }
        } else {
          reject(new Error(`Gateway ${res.statusCode}: ${data.slice(0, 200)}`));
        }
      });
    });
    req.on("error", reject);
    req.end(payload);
  });
}

// ---------- Delivery: reply first, fallback to push ----------

async function deliverResponse(userId, replyToken, text, startTime) {
  const elapsed = Date.now() - startTime;
  const replyTokenAlive = elapsed < 55000; // LINE token ~60s, use 55s safety margin

  if (replyTokenAlive) {
    try {
      await replyLine(replyToken, text);
      console.log(`[${ts()}] REPLY sent to ${userId} (${elapsed}ms)`);
      return;
    } catch (err) {
      console.log(`[${ts()}] Reply failed (${err.message}), falling back to push`);
    }
  } else {
    console.log(`[${ts()}] Reply token expired (${elapsed}ms), using push`);
  }

  // Fallback to push
  try {
    await pushLine(userId, text);
    console.log(`[${ts()}] PUSH sent to ${userId}`);
  } catch (pushErr) {
    console.error(`[${ts()}] PUSH also failed: ${pushErr.message}`);
  }
}

// ---------- Event processing ----------

// Get bot's display name and user ID (cached after first fetch)
let botUserId = null;
let botDisplayName = null;

// TODO: Add your bot's trigger names here
// These are names/aliases that users can type in group chats to trigger the bot
// Example: ["MyBot", "AI Assistant", "Bot"]
const BOT_TRIGGER_NAMES = [];

async function getBotInfo() {
  if (botUserId) return;
  try {
    const data = await new Promise((resolve, reject) => {
      const req = https.request("https://api.line.me/v2/bot/info", {
        method: "GET",
        headers: { "Authorization": `Bearer ${LINE_TOKEN}` },
      }, (res) => {
        let d = "";
        res.on("data", (c) => d += c);
        res.on("end", () => {
          if (res.statusCode === 200) resolve(JSON.parse(d));
          else reject(new Error(`${res.statusCode}`));
        });
      });
      req.on("error", reject);
      req.end();
    });
    botUserId = data.userId;
    botDisplayName = data.displayName;
    console.log(`[${ts()}] Bot: ${botDisplayName} (${botUserId})`);
  } catch (err) {
    console.error(`[${ts()}] Failed to get bot info: ${err.message}`);
  }
}

// TODO: Add command trigger keywords for group chats (no bot name needed)
// These keywords will trigger the bot in group chats without needing @mention
// Example: ["report", "status", "help"]
const GROUP_COMMAND_TRIGGERS = [];

// Check if bot is triggered in a group message:
// 1. @mention (LINE mention API)
// 2. Message contains bot display name or trigger names
// 3. Message exactly matches a command trigger keyword (no bot name needed)
function isBotTriggered(event) {
  const text = (event.message?.text || "").trim();
  // Check @mention
  const mention = event.message?.mention;
  if (mention?.mentionees?.length) {
    if (mention.mentionees.some(m => m.type === "user" && m.userId === botUserId)) return true;
  }
  // Check trigger names (bot display name + aliases)
  const names = [...BOT_TRIGGER_NAMES];
  if (botDisplayName && !names.includes(botDisplayName)) names.push(botDisplayName);
  if (names.some(name => text.includes(name))) return true;
  // Check command triggers (exact match or message starts/ends with keyword)
  const lower = text.toLowerCase();
  return GROUP_COMMAND_TRIGGERS.some(cmd => lower === cmd.toLowerCase() || text === cmd);
}

// Strip bot name / @mention from message text
function stripTrigger(text) {
  let cleaned = text.replace(/@\S+/g, ""); // strip @mentions
  const names = [...BOT_TRIGGER_NAMES];
  if (botDisplayName) names.push(botDisplayName);
  for (const name of names) {
    cleaned = cleaned.replaceAll(name, "");
  }
  return cleaned.trim();
}

async function processTextMessage(event) {
  const userId = event.source?.userId || "unknown";
  const sourceType = event.source?.type || "user"; // "user", "group", "room"
  const groupId = event.source?.groupId || event.source?.roomId || null;
  const isGroup = sourceType === "group" || sourceType === "room";
  const text = event.message.text;
  const replyToken = event.replyToken;
  const startTime = Date.now();

  // Build session key: dm or group
  const sessionKey = isGroup
    ? `line:group:${groupId}`
    : `line:dm:${userId}`;

  // Build push target: group or user
  const pushTarget = isGroup ? groupId : userId;

  // Strip trigger name / @mention from group messages
  const cleanText = isGroup ? stripTrigger(text) : text;
  if (!cleanText) return; // Empty after stripping mention

  const label = isGroup ? `${userId}@${groupId}` : userId;
  console.log(`[${ts()}] MSG from ${label}: ${text.slice(0, 80)}`);

  // Show loading animation (only works for 1-on-1 chats)
  if (!isGroup) {
    showLoadingAnimation(userId, 60).catch(() => {});
  }

  try {
    const aiResponse = await chatComplete(cleanText, sessionKey);
    if (!aiResponse) {
      console.log(`[${ts()}] WARN: empty AI response`);
      await deliverResponse(pushTarget, replyToken, "\uff08AI \u6c92\u6709\u7522\u751f\u56de\u8986\uff0c\u8acb\u518d\u8a66\u4e00\u6b21\u6216\u63db\u500b\u554f\u6cd5\uff09", startTime);
      return;
    }
    const formatted = mdToLine(aiResponse);
    console.log(`[${ts()}] AI: ${formatted.slice(0, 80)}...`);
    await deliverResponse(pushTarget, replyToken, formatted, startTime);
  } catch (err) {
    console.error(`[${ts()}] ERROR: ${err.message}`);
    await deliverResponse(pushTarget, replyToken, "\u62b1\u6b49\uff0c\u6211\u66ab\u6642\u7121\u6cd5\u8655\u7406\u4f60\u7684\u8a0a\u606f\uff0c\u8acb\u7a0d\u5f8c\u518d\u8a66\u3002", startTime);
  }
}

async function processEvent(event) {
  // Handle non-message events (follow, unfollow, join, etc.)
  if (event.type !== "message") {
    console.log(`[${ts()}] SKIP: event type=${event.type}`);
    return;
  }

  const userId = event.source?.userId || "unknown";
  const sourceType = event.source?.type || "user";
  const isGroup = sourceType === "group" || sourceType === "room";

  // Only text messages are supported
  if (event.message?.type !== "text") {
    const msgType = event.message?.type || "unknown";
    console.log(`[${ts()}] SKIP: non-text message type=${msgType} from ${userId}`);
    if (event.replyToken && msgType !== "sticker" && !isGroup) {
      try {
        await replyLine(event.replyToken, `\u76ee\u524d\u53ea\u652f\u63f4\u6587\u5b57\u8a0a\u606f\uff0c${msgType === "image" ? "\u5716\u7247\u8fa8\u8b58" : msgType + " \u8a0a\u606f"}\u529f\u80fd\u5c1a\u672a\u958b\u653e\u3002`);
      } catch {}
    }
    return;
  }

  // In groups: only respond when triggered (name mentioned or @mentioned)
  if (isGroup) {
    if (!isBotTriggered(event)) return; // Silently ignore
  }

  // Queue per user (or per group) to prevent concurrent stomping
  const queueKey = isGroup
    ? (event.source?.groupId || event.source?.roomId || userId)
    : userId;
  enqueueForUser(queueKey, () => processTextMessage(event));
}

// ---------- HTTP server ----------

const server = http.createServer((req, res) => {
  console.log(`[${ts()}] HTTP ${req.method} ${req.url} from ${req.socket.remoteAddress}`);

  if (req.url === "/health" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", uptime: process.uptime() | 0 }));
    return;
  }

  if (req.url !== "/line/webhook" || req.method !== "POST") {
    res.writeHead(404);
    res.end("Not Found");
    return;
  }

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");
    const signature = req.headers["x-line-signature"];

    if (!signature || !validateSignature(body, signature)) {
      console.log(`[${ts()}] REJECT: bad signature`);
      res.writeHead(401);
      res.end("Unauthorized");
      return;
    }

    let parsed;
    try { parsed = JSON.parse(body); } catch {
      res.writeHead(400);
      res.end("Bad Request");
      return;
    }

    const events = parsed.events || [];
    console.log(`[${ts()}] RECV: ${events.length} event(s)`);

    // Respond 200 immediately (LINE requires response within 1 second)
    res.writeHead(200);
    res.end("OK");

    // Process events asynchronously
    for (const event of events) {
      processEvent(event).catch((err) => {
        console.error(`[${ts()}] Unhandled: ${err.message}`);
      });
    }
  });
});

// ---------- Graceful shutdown ----------

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[${ts()}] ${signal} received, shutting down...`);
  server.close(() => {
    console.log(`[${ts()}] Server closed`);
    // Wait a bit for in-flight requests to finish
    setTimeout(() => process.exit(0), 3000);
  });
  // Force exit after 10s
  setTimeout(() => process.exit(1), 10000);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ---------- Start ----------

server.listen(PROXY_PORT, "127.0.0.1", () => {
  console.log(`LINE Webhook Proxy listening on http://127.0.0.1:${PROXY_PORT}`);
  console.log(`Gateway: ${GATEWAY_URL}`);
  if (!LINE_TOKEN) console.warn("WARNING: LINE_CHANNEL_ACCESS_TOKEN not set!");
  if (!LINE_SECRET) console.warn("WARNING: LINE_CHANNEL_SECRET not set!");
  if (!GATEWAY_PASSWORD) console.warn("WARNING: GATEWAY_PASSWORD not set - chat API calls will fail");
  // Fetch bot info for group trigger detection
  getBotInfo().catch(() => {});
});
