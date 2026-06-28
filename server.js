const express = require("express");
const path    = require("path");
const fs      = require("fs");
const http    = require("http");

try { require("compression"); } catch { console.log("Run: npm install express compression ws"); process.exit(1); }

const compression = require("compression");
const app  = express();
const PORT = process.env.PORT || 3000;

app.use(compression());
app.use(express.json({ limit: "10mb" }));

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(200);
  next();
});

app.use((req, res, next) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "SAMEORIGIN");
  next();
});

const DATA_DIR  = path.join(__dirname, "data");
const DATA_FILE = path.join(DATA_DIR, "store.json");

function readStore() {
  try {
    if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
    if (!fs.existsSync(DATA_FILE)) return {};
    return JSON.parse(fs.readFileSync(DATA_FILE, "utf8"));
  } catch { return {}; }
}

function writeStore(data) {
  try {
    if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
    return true;
  } catch (e) { console.error("Write error:", e.message); return false; }
}

app.get("/api/health", (req, res) => {
  res.json({ status: "ok", time: new Date().toISOString(), version: "2.0.0" });
});

app.post("/api/sync/:userId", (req, res) => {
  const { userId } = req.params;
  const { data } = req.body;
  if (!userId || !data) return res.status(400).json({ error: "userId and data required" });

  const store = readStore();
  const existing = store[userId];

  if (existing?.lastSaved && data.lastSaved) {
    if (new Date(existing.lastSaved) > new Date(data.lastSaved)) {
      return res.json({ status: "conflict", serverData: existing });
    }
  }

  store[userId] = { ...data, lastSaved: new Date().toISOString() };
  writeStore(store);

  broadcastToUser(userId, { type: "sync", data: store[userId] });

  res.json({ status: "ok", lastSaved: store[userId].lastSaved });
});

app.get("/api/sync/:userId", (req, res) => {
  const store = readStore();
  const data  = store[req.params.userId];
  if (!data) return res.json({ status: "empty" });
  res.json({ status: "ok", data });
});

app.delete("/api/sync/:userId", (req, res) => {
  const store = readStore();
  delete store[req.params.userId];
  writeStore(store);
  res.json({ status: "ok" });
});

const distDir = path.join(__dirname, "dist");
if (fs.existsSync(distDir)) {
  app.use(express.static(distDir, {
    maxAge: "1d",
    setHeaders(res, filePath) {
      if (filePath.endsWith("service-worker.js") || filePath.endsWith("manifest.json")) {
        res.setHeader("Cache-Control", "no-cache");
      }
    },
  }));
  app.get("*", (req, res) => res.sendFile(path.join(distDir, "index.html")));
} else {
  app.get("/", (req, res) => {
    res.send(`<!DOCTYPE html><html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TradePro Server</title>
<style>body{background:#0F172A;color:#fff;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center}
h1{color:#F97316;font-size:2rem;margin-bottom:16px}p{color:#94A3B8;margin:6px 0}
code{background:#1E293B;padding:3px 10px;border-radius:6px;color:#10B981;font-size:14px}</style>
</head><body><div>
<h1>⚡ TradePro Server</h1>
<p>السيرفر يعمل على البورت <code>${PORT}</code></p>
<p>ضع ملفات البناء في مجلد <code>dist/</code></p>
<p style="margin-top:20px">API Health: <code>GET /api/health</code></p>
<p>Sync Push:  <code>POST /api/sync/:userId</code></p>
<p>Sync Pull:  <code>GET /api/sync/:userId</code></p>
</div></body></html>`);
  });
}

const server = http.createServer(app);
const clients = new Map();

function broadcastToUser(userId, msg) {
  const peers = clients.get(userId);
  if (!peers) return;
  const raw = JSON.stringify(msg);
  peers.forEach(ws => {
    if (ws.readyState === 1) ws.send(raw);
  });
}

try {
  const { WebSocketServer } = require("ws");
  const wss = new WebSocketServer({ server });

  wss.on("connection", (ws) => {
    let userId = null;

    ws.on("message", (raw) => {
      try {
        const msg = JSON.parse(raw.toString());

        if (msg.type === "register" && msg.userId) {
          userId = msg.userId;
          if (!clients.has(userId)) clients.set(userId, new Set());
          clients.get(userId).add(ws);
          ws.send(JSON.stringify({ type: "registered", userId }));

          const store = readStore();
          if (store[userId]) {
            ws.send(JSON.stringify({ type: "init", data: store[userId] }));
          }
        }

        if (msg.type === "update" && userId && msg.data) {
          const store = readStore();
          store[userId] = { ...msg.data, lastSaved: new Date().toISOString() };
          writeStore(store);
          const peers = clients.get(userId) || new Set();
          peers.forEach(peer => {
            if (peer !== ws && peer.readyState === 1) {
              peer.send(JSON.stringify({ type: "sync", data: store[userId] }));
            }
          });
        }
      } catch {}
    });

    ws.on("close", () => {
      if (userId && clients.has(userId)) {
        clients.get(userId).delete(ws);
        if (clients.get(userId).size === 0) clients.delete(userId);
      }
    });

    ws.on("error", () => ws.close());
  });

  console.log("✅ WebSocket enabled — real-time sync active");
} catch {
  console.log("⚠️  ws not installed — run: npm install ws");
}

server.listen(PORT, "0.0.0.0", () => {
  const os   = require("os");
  const nets = os.networkInterfaces();
  const ip   = Object.values(nets).flat().find(n => n.family === "IPv4" && !n.internal)?.address || "localhost";

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║       ⚡ TradePro Server Started         ║");
  console.log("╠══════════════════════════════════════════╣");
  console.log(`║  Local:    http://localhost:${PORT}           ║`);
  console.log(`║  Network:  http://${ip}:${PORT}       ║`);
  console.log(`║  API:      http://localhost:${PORT}/api      ║`);
  console.log("╚══════════════════════════════════════════╝");
  console.log(`\n📱 الجوال:  http://${ip}:${PORT}`);
  console.log(`💻 اللابتوب: http://localhost:${PORT}\n`);
});
