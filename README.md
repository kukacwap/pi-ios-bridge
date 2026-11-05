# pi-ios-bridge

Run a **pi coding agent driven entirely by local models** (Ollama on your Mac)
and control it from an **iOS / iPadOS** app over your LAN or Tailscale.
No Anthropic / cloud dependency.

```
[iOS/iPadOS Swift app]  --WebSocket-->  [pi-ios-bridge (Node)]  --spawn/JSONL-->  pi --mode rpc  -->  Ollama
                                                                                 (provider=ollama, model=qwen3-coder)
```

## Why a bridge?

`pi` is a Node/TypeScript agent and cannot run on iOS. The bridge runs on the
Mac, spawns one `pi --mode rpc` child per connected device, and relays the RPC
JSONL protocol over an authenticated WebSocket. The Swift app is a thin client.

## Prerequisites

- `pi` installed (`which pi`) and the `ollama` provider configured in
  `~/.pi/agent/models.json` (already done: `qwen3-coder:latest`, `qwen3.8:27b-mlx`,
  `flint:latest`).
- Ollama running: `ollama serve` (and the model pulled).
- Node 18+ (bundled pi node is v22).

## Adding a local model to the rotatable list

The app's model switcher is populated by pi's `get_available_models`, which reads
`~/.pi/agent/models.json`. It does **not** auto-discover Ollama's library, so any
model you want to rotate to must be listed there under the `ollama` provider.

1. Pull it with Ollama:  `ollama pull flint`
2. Add an entry to the `ollama.models` array in `~/.pi/agent/models.json`:
   ```json
   {
     "id": "flint:latest",
     "name": "Flint (local)",
     "reasoning": false,
     "input": ["text"],
     "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
     "contextWindow": 262144,
     "maxTokens": 8192
   }
   ```
   - `reasoning`: `true` only for thinking-capable models (qwen3-coder); `false`
     otherwise. `input`: `["text"]` or `["text","image"]` for vision.
   - Get context/params from `ollama.com/library/<model>` or
     `curl localhost:11434/api/show -d '{"name":"<model>"}'`.
3. Restart the bridge so pi reloads the config:
   ```bash
   cd ~/pi-ios-bridge && ./service.sh restart
   ```
4. The model now appears in the app's switcher on next connect (the app keeps
   only local providers: `ollama`, `llama-cpp`, `lmstudio`, `vllm`).

## Run the bridge

```bash
cd ~/pi-ios-bridge
cp .env.example .env            # then edit BRIDGE_TOKEN + PI_CWD
set -a; source .env; set +a
npm start
```

Smoke test locally (separate shell):

```bash
cd ~/pi-ios-bridge
set -a; source .env; set +a
node smoke-test.js "Create hello.txt with 'hi', then say done."
```

## Expose to your iPad

**Tailscale (recommended).** Install Tailscale on the Mac and iPad, same tailnet.
Set `BRIDGE_HOST` to the Mac's Tailscale IP (`100.x.y.z`) so it only listens on
the tailnet, then connect the app to that IP:8787. Traffic is encrypted by
Tailscale; `ws://` is fine inside the tunnel.

**Plain LAN.** Set `BRIDGE_HOST=0.0.0.0`, find the Mac IP (`ipconfig getifaddr en0`),
connect to `ws://<mac-ip>:8787`. Only do this on a trusted network. For public
exposure, terminate TLS with a reverse proxy (Caddy/nginx) and use `wss://`.

## Security

- `BRIDGE_TOKEN` is a required shared secret (query `?token=` or
  `Authorization: Bearer`). Unauthenticated sockets are closed with 4401.
- The agent can run shell commands and read/write files in `PI_CWD`. Point
  `PI_CWD` at a dedicated workspace, **not** your home directory.
- Prefer binding to a Tailscale IP over `0.0.0.0`.

## Wire protocol (client → bridge)

Send JSON objects. Allowlisted command `type`s are forwarded to pi RPC:

| type | purpose |
|---|---|
| `prompt` | `{type:"prompt", message, id?}` — start/queue a run |
| `steer` / `follow_up` | interject during / after the current run |
| `abort` | stop the active run |
| `get_state`, `get_messages`, `get_last_assistant_text` | inspect |
| `set_model`, `get_available_models`, `cycle_model` | model control |
| `set_thinking_level`, `get_available_thinking_levels` | reasoning control |
| `new_session`, `compact`, `get_session_stats` | session control |
| `ping` | bridge-local health check → `pong` |

## Events (bridge → client)

- `bridge_ready` — `{model, provider, cwd}` on connect
- `message_update` — streaming deltas; read `assistantMessageEvent.type`:
  `text_delta` / `thinking_delta` carry `.delta`
- `tool_execution_start` — `{toolName}`
- `message_end` — authoritative completed message (replace streamed text)
- `agent_settled` — run finished; pi won't continue automatically
- `bridge_error` / `bridge_notice` — bridge-level diagnostics

Reconstruction rule: accumulate `text_delta`s for live UI, then replace with the
`message_end` message. Wait for `agent_settled` to re-enable the input box.

## iOS client

`ios/PiAgentClient.swift` is a dependency-free `URLSessionWebSocketTask` client.
Usage sketch:

```swift
let client = PiAgentClient(config: .init(host: "100.x.y.z", token: "<BRIDGE_TOKEN>"))
client.onEvent = { event in
    switch event {
    case .ready(let model, _): print("connected to \(model)")
    case .textDelta(let s):    appendToTranscript(s)
    case .toolStart(let name): showToolBadge(name)
    case .settled:             enableInput()
    case .bridgeError(let e):  showError(e)
    default: break
    }
}
client.connect()
client.prompt("List the files in the workspace and summarize them.")
```

## Run as a background service (launchd)

The bridge ships with a `launchd` job that starts it at login and keeps it alive.

```bash
cd ~/pi-ios-bridge
./service.sh install     # copy plist + bootstrap
./service.sh status      # state = running, pid = ...
./service.sh restart     # after editing .env or server.js
./service.sh logs        # tail stderr log
./service.sh uninstall   # stop + remove
```

`run-bridge.sh` loads `.env` and launches `server.js`; the plist points at it.
Logs go to `bridge.out.log` / `bridge.err.log`. Keep `.env` (the token) out of git.

## The iOS / iPadOS app

See [`ios/README.md`](ios/README.md). SwiftUI chat client with streaming text,
tool badges, and a local-only model switcher. Build it with XcodeGen
(`cd ios/PiAgentApp && xcodegen generate`) or by dropping `Sources/` into a new
Xcode app target. Configure it with the Mac's Tailscale IP, port `8787`, and the
`BRIDGE_TOKEN`.

## Files

- `server.js` — the bridge (WebSocket ⇄ pi RPC), local-only enforcement
- `run-bridge.sh` / `service.sh` / `com.local.pi-ios-bridge.plist` — launchd service
- `smoke-test.js` — local end-to-end check
- `ios/PiAgentApp/` — SwiftUI app (XcodeGen `project.yml` + `Sources/`)
- `.env.example` — configuration template
```
