#!/usr/bin/env node
/**
 * pi-ios-bridge  —  Solution B: real session attachment.
 *
 * ONE long-lived `pi --mode rpc` process is shared by ALL connected clients.
 * Events from pi are broadcast to every attached client; commands from any
 * client go to the single pi stdin. This is true "attach to a running session":
 * your phone and Mac see the same live stream, no per-connection respawn.
 *
 *   [Swift app] --WebSocket--> [bridge: 1 shared pi] --JSONL--> [pi rpc] --> [Ollama]
 *
 * Config (env, see .env.example):
 *   BRIDGE_TOKEN       required shared secret
 *   BRIDGE_HOST        bind address (default 0.0.0.0 — use Tailscale IP)
 *   BRIDGE_PORT        listen port   (default 8787)
 *   PI_BIN             path to pi CLI
 *   BRIDGE_PROVIDER    default "ollama"
 *   BRIDGE_MODEL       default "qwen3-coder:latest"
 *   BRIDGE_CWD         workspace dir pi operates in
 *   BRIDGE_SESSION_DIR where pi persists sessions (default <PI_CWD>/.pi-sessions)
 *   BRIDGE_OPEN_SESSION  optional session file to open at startup
 *
 * We deliberately do NOT read pi's own PI_PROVIDER / PI_MODEL env vars.
 */

import { spawn } from "node:child_process";
import { WebSocketServer } from "ws";
import { randomUUID } from "node:crypto";
import { readdirSync, statSync, readFileSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";

const TOKEN = process.env.BRIDGE_TOKEN;
const HOST = process.env.BRIDGE_HOST || "0.0.0.0";
const PORT = Number(process.env.BRIDGE_PORT || 8787);
const PI_BIN = process.env.PI_BIN || "pi";
const PI_PROVIDER = process.env.BRIDGE_PROVIDER || "ollama";
const PI_MODEL = process.env.BRIDGE_MODEL || "qwen3-coder:latest";
const PI_CWD = process.env.BRIDGE_CWD || process.cwd();
const SESSION_DIR = process.env.BRIDGE_SESSION_DIR || join(PI_CWD, ".pi-sessions");
const OPEN_SESSION = process.env.BRIDGE_OPEN_SESSION;

// Scrub pi's own model/provider selectors so an inherited cloud selection can't win.
const CHILD_ENV = { ...process.env };
for (const k of ["PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL"]) delete CHILD_ENV[k];
// Local-only providers a client may switch to.
const LOCAL_PROVIDERS = new Set(
  (process.env.LOCAL_PROVIDERS || "ollama,llama-cpp,lmstudio,vllm")
    .split(",").map((s) => s.trim()).filter(Boolean)
);

if (!TOKEN) { console.error("FATAL: BRIDGE_TOKEN must be set"); process.exit(1); }
try { mkdirSync(SESSION_DIR, { recursive: true }); } catch {}

// RPC commands a client may forward verbatim to the shared pi process.
const ALLOWED_COMMANDS = new Set([
  "prompt", "steer", "follow_up", "abort", "clear_queue",
  "get_state", "get_messages", "get_last_assistant_text", "get_entries", "get_tree",
  "set_model", "cycle_model", "get_available_models",
  "set_thinking_level", "cycle_thinking_level", "get_available_thinking_levels",
  "new_session", "switch_session", "fork", "clone", "get_fork_messages", "set_session_name",
  "compact", "set_auto_compaction", "get_session_stats",
  "set_auto_retry", "abort_retry",
  "bash", "abort_bash",
  "export_html",
  "get_commands",
]);
const EXT_UI_RESPONSE = new Set(["extension_ui_response"]);

function log(...a) { console.error(new Date().toISOString(), ...a); }

// --- Session name sidecar (pi doesn't persist names in the file header) ------
const NAMES_FILE = join(SESSION_DIR, "names.json");
let nameMap = {};
try { if (existsSync(NAMES_FILE)) nameMap = JSON.parse(readFileSync(NAMES_FILE, "utf8")); } catch {}
function persistNames() { try { writeFileSync(NAMES_FILE, JSON.stringify(nameMap, null, 2)); } catch {} }

/** Scan the session dir and return metadata for each .jsonl session. */
function listSessions() {
  const out = [];
  let files = [];
  try { files = readdirSync(SESSION_DIR).filter((f) => f.endsWith(".jsonl")); } catch {}
  for (const f of files) {
    const path = join(SESSION_DIR, f);
    let mtime = 0, preview = "";
    try {
      mtime = statSync(path).mtimeMs;
      const head = readFileSync(path, "utf8").split("\n").slice(0, 60).join("\n");
      for (const line of head.split("\n")) {
        if (!line.trim()) continue;
        try {
          const e = JSON.parse(line);
          const m = e.message || e;
          if (m.role === "user" && typeof m.text === "string") { preview = m.text.slice(0, 120); break; }
          if (m.role === "user" && Array.isArray(m.content)) {
            const t = m.content.find((c) => c.type === "text");
            if (t?.text) { preview = t.text.slice(0, 120); break; }
          }
        } catch {}
      }
    } catch {}
    out.push({ path, name: nameMap[path] || f.replace(/\.jsonl$/, ""), mtime, preview });
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

/** Run `git diff` in the workspace without polluting the model context. */
function gitDiff(staged = false) {
  return new Promise((resolve) => {
    const c = spawn("git", staged ? ["diff", "--staged"] : ["diff"], { cwd: PI_CWD });
    let out = "", err = "";
    c.stdout.on("data", (d) => { out += d.toString(); if (out.length > 200_000) c.kill(); });
    c.stderr.on("data", (d) => { err += d.toString(); });
    c.on("error", () => resolve({ output: "", exitCode: -1, error: "git not found" }));
    c.on("close", (code) => resolve({ output: out, exitCode: code ?? 0, error: err.trim() || undefined }));
  });
}

// --- The single shared pi process ------------------------------------------
let child = null;
let currentSessionFile = null;   // tracked for the name sidecar

function spawnPi() {
  const args = ["--mode", "rpc", "--session-dir", SESSION_DIR,
                "--provider", PI_PROVIDER, "--model", PI_MODEL];
  if (OPEN_SESSION) args.push("--session", OPEN_SESSION);
  child = spawn(PI_BIN, args, { cwd: PI_CWD, stdio: ["pipe", "pipe", "pipe"], env: CHILD_ENV });

  child.stdout.on("data", createLineSplitter((line) => {
    let record;
    try { record = JSON.parse(line); } catch { log("non-JSON stdout:", line.slice(0, 200)); return; }

    if (record.type === "response") {
      // Bridge-internal requests (session tracking): never shown to clients.
      if (typeof record.id === "string" && record.id.startsWith(INTERNAL_PREFIX)) {
        if (record.command === "get_state" && record.success) {
          currentSessionFile = record.data?.sessionFile || null;
        }
        return;
      }
      // Restore the client's own id and find out who asked.
      const route = typeof record.id === "string" ? pending.get(record.id) : undefined;
      if (route) { pending.delete(record.id); record.id = route.origId; }

      // A session-changing command finished: learn the new session file and
      // release commands that were held back behind it.
      if (SESSION_CHANGING.has(record.command)) {
        writeRaw({ type: "get_state", id: INTERNAL_PREFIX + "state-" + randomUUID().slice(0, 8) });
        releaseBarrier();
      }

      // Responses go back to the requesting client only, except for commands
      // that change shared state — every attached client must resync on those.
      if (route && !BROADCAST_RESPONSES.has(record.command)) {
        if (route.ws.readyState === route.ws.OPEN) route.ws.send(JSON.stringify(record));
        return;
      }
      broadcast(record);
      return;
    }

    // Track session name changes into the sidecar.
    if (record.type === "session_info_changed" && currentSessionFile) {
      const name = record.name;
      if (name) { nameMap[currentSessionFile] = name; persistNames(); }
    }
    broadcast(record);
  }));

  child.stderr.on("data", (b) => { const s = b.toString().trimEnd(); if (s) log("pi:", s); });
  child.on("exit", (code, signal) => {
    log(`shared pi exited code=${code} signal=${signal}`);
    broadcast({ type: "bridge_notice", event: "pi_exited", code, signal });
    child = null;
    pending.clear();
    releaseBarrier();
  });
  child.on("error", (err) => {
    log("spawn error:", err.message);
    broadcast({ type: "bridge_error", error: `spawn failed: ${err.message}` });
  });
  return child;
}

// --- Client registry --------------------------------------------------------
const clients = new Set();
function broadcast(obj) {
  const s = JSON.stringify(obj);
  for (const ws of clients) if (ws.readyState === ws.OPEN) ws.send(s);
}
function writeRaw(cmd) {
  if (!child) spawnPi();
  try { child.stdin.write(JSON.stringify(cmd) + "\n"); }
  catch (err) { broadcast({ type: "bridge_error", error: `write failed: ${err.message}` }); }
}

// --- Request routing + session-switch barrier -------------------------------
// pi processes switch_session/new_session/fork/clone asynchronously: a command
// written right after one of them (e.g. get_messages) can be answered with the
// OLD session's data. So while a session-changing command is in flight, later
// commands are held back and flushed once its response arrives.
const INTERNAL_PREFIX = "__bridge:";
const SESSION_CHANGING = new Set(["new_session", "switch_session", "fork", "clone"]);
const BROADCAST_RESPONSES = new Set([
  ...SESSION_CHANGING, "set_model", "cycle_model", "set_thinking_level",
  "cycle_thinking_level", "set_session_name", "compact",
]);
const pending = new Map();       // bridge id -> { ws, origId }
let barrier = null;              // { timer } while a session change is in flight
const held = [];                 // commands queued behind the barrier

function releaseBarrier() {
  if (!barrier) return;
  clearTimeout(barrier.timer);
  barrier = null;
  while (held.length && !barrier) dispatch(held.shift());
}

function dispatch(cmd) {
  writeRaw(cmd);
  if (SESSION_CHANGING.has(cmd.type)) {
    barrier = { timer: setTimeout(() => { log("session barrier timed out"); releaseBarrier(); }, 30_000) };
  }
}

/** Forward a client command to pi; its response is routed back to `ws`. */
function writeCommand(cmd, ws, connId) {
  const origId = cmd.id;
  const bridgeId = `${connId}:${origId}`;
  pending.set(bridgeId, { ws, origId });
  const out = { ...cmd, id: bridgeId };
  if (barrier) held.push(out); else dispatch(out);
}

// --- Strict JSONL reader ----------------------------------------------------
function createLineSplitter(onLine) {
  let buffer = Buffer.alloc(0);
  return (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    let idx;
    while ((idx = buffer.indexOf(0x0a)) !== -1) {
      let line = buffer.subarray(0, idx);
      buffer = buffer.subarray(idx + 1);
      if (line.length && line[line.length - 1] === 0x0d) line = line.subarray(0, line.length - 1);
      if (line.length) onLine(line.toString("utf8"));
    }
  };
}

const wss = new WebSocketServer({ host: HOST, port: PORT });
log(`pi-ios-bridge (shared mode) listening on ws://${HOST}:${PORT}`);
log(`provider=${PI_PROVIDER} model=${PI_MODEL} cwd=${PI_CWD} sessions=${SESSION_DIR}`);

// Start the shared pi eagerly so it's "live" even before a client connects.
spawnPi();

wss.on("connection", (ws, req) => {
  const auth = req.headers["authorization"];
  const headerToken = auth?.startsWith("Bearer ") ? auth.slice(7) : undefined;
  const url = new URL(req.url, "http://localhost");
  const provided = headerToken ?? url.searchParams.get("token") ?? undefined;

  if (provided !== TOKEN) { log("auth rejected from", req.socket.remoteAddress); ws.close(4401, "unauthorized"); return; }

  const connId = randomUUID().slice(0, 8);
  clients.add(ws);
  log(`[${connId}] attached from ${req.socket.remoteAddress} (clients=${clients.size})`);

  // Learn the current session file so name changes can be recorded.
  writeRaw({ type: "get_state", id: INTERNAL_PREFIX + "state-" + connId });

  ws.on("message", async (data) => {
    let msg;
    try { msg = JSON.parse(data.toString("utf8")); }
    catch { broadcast({ type: "bridge_error", error: "invalid JSON from client" }); return; }
    if (!msg || typeof msg.type !== "string") { broadcast({ type: "bridge_error", error: "missing command type" }); return; }
    if (typeof msg.id !== "string" || !msg.id) msg.id = randomUUID().slice(0, 8);

    // Bridge-local commands (never forwarded to pi).
    switch (msg.type) {
      case "ping":
        ws.send(JSON.stringify({ type: "pong", id: msg.id, t: Date.now() })); return;
      case "list_sessions":
        ws.send(JSON.stringify({ type: "response", command: "list_sessions", id: msg.id, success: true, data: { sessions: listSessions() } })); return;
      case "diff":
        try {
          const res = await gitDiff(msg.staged === true);
          ws.send(JSON.stringify({ type: "response", command: "diff", id: msg.id, success: res.exitCode === 0 || res.output.length > 0, data: res }));
        } catch (e) { broadcast({ type: "bridge_error", id: msg.id, error: `diff failed: ${e.message}` }); }
        return;
    }

    if (EXT_UI_RESPONSE.has(msg.type)) { writeRaw(msg); return; }

    if (!ALLOWED_COMMANDS.has(msg.type)) {
      ws.send(JSON.stringify({ type: "bridge_error", id: msg.id, error: `command not allowed: ${msg.type}` })); return;
    }
    if (msg.type === "set_model" && !LOCAL_PROVIDERS.has(msg.provider)) {
      ws.send(JSON.stringify({ type: "bridge_error", id: msg.id, error: `provider not allowed: ${msg.provider}` })); return;
    }
    writeCommand(msg, ws, connId);
  });

  ws.on("close", () => {
    clients.delete(ws);
    for (const [k, v] of pending) if (v.ws === ws) pending.delete(k);
    log(`[${connId}] detached (clients=${clients.size})`);
    // NOTE: we do NOT kill the shared pi — other clients may still be attached.
  });

  // Greet with connection metadata.
  ws.send(JSON.stringify({
    type: "bridge_ready", connId, provider: PI_PROVIDER, model: PI_MODEL,
    cwd: PI_CWD, sessionDir: SESSION_DIR, mode: "shared",
  }));
});

// Orderly shutdown of the shared pi.
function shutdown() {
  log("shutting down");
  try { child?.stdin.end(); } catch {}
  setTimeout(() => { if (child && !child.killed) child.kill("SIGTERM"); }, 1500);
  setTimeout(() => { if (child && !child.killed) child.kill("SIGKILL"); }, 4000);
  wss.close(); process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
