#!/usr/bin/env node
/** Minimal WS client to verify the bridge end-to-end against the local model. */
import WebSocket from "ws";

const PORT = process.env.BRIDGE_PORT || 8787;
const TOKEN = process.env.BRIDGE_TOKEN || "change-me";
const PROMPT = process.argv.slice(2).join(" ") || "In one short sentence, what are you running on?";

const ws = new WebSocket(`ws://127.0.0.1:${PORT}/?token=${encodeURIComponent(TOKEN)}`);

ws.on("open", () => {
  console.error("[open] sending prompt:", PROMPT);
  ws.send(JSON.stringify({ type: "prompt", id: "p1", message: PROMPT }));
});

ws.on("message", (data) => {
  const r = JSON.parse(data.toString());
  if (r.type === "bridge_ready") {
    console.error(`[ready] model=${r.model} provider=${r.provider}`);
  } else if (r.type === "message_update" && r.assistantMessageEvent?.type === "text_delta") {
    process.stdout.write(r.assistantMessageEvent.delta);
  } else if (r.type === "tool_execution_start") {
    console.error(`\n[tool] ${r.toolName}`);
  } else if (r.type === "agent_settled") {
    process.stdout.write("\n");
    console.error("[settled] done");
    ws.close();
  } else if (r.type === "bridge_error" || r.type === "bridge_notice") {
    console.error("[bridge]", JSON.stringify(r));
  }
});

ws.on("close", (code) => { console.error("[close]", code); process.exit(0); });
ws.on("error", (e) => { console.error("[error]", e.message); process.exit(1); });
