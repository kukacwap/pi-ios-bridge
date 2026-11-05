# PiAgentApp (iOS / iPadOS)

A SwiftUI client for `pi-ios-bridge`. Chat with a **local-model** pi agent on your
Mac over Tailscale. Streams assistant text, shows tool badges, and lets you switch
between local models.

## Build

Two options.

### Option 1 — XcodeGen (fastest)

```bash
brew install xcodegen
cd ios/PiAgentApp
xcodegen generate
open PiAgentApp.xcodeproj
```

### Option 2 — Manual Xcode project

1. Xcode → New → App → SwiftUI, name `PiAgentApp`, iOS 17+.
2. Delete the generated `ContentView.swift` and `*App.swift`.
3. Drag everything in `Sources/` into the target.
4. Build to your iPad.

## Configure

On first launch the Settings sheet appears. Enter:

- **Host** — your **Mac's Tailscale IP** (`tailscale ip -4` on the Mac, e.g. `100.x.y.z`).
- **Port** — `8787` (matches `BRIDGE_PORT`).
- **Token** — the same value as `BRIDGE_TOKEN` in the bridge `.env` (stored in the iOS Keychain).

Tap **Save & Connect**. The status dot turns green and the title shows the active model.

## Use

- Type a message → the agent runs; assistant text streams in, tool use shows as
  orange badges (`bash`, `read`, `write`, …).
- While a run is active the input box **steers** the run; the stop button aborts.
- Toolbar center: **model switcher** (local providers only — Claude is filtered out
  and blocked by the bridge).
- `…` menu: new session, toggle thinking view, settings, connect/disconnect.

## Files

| File | Role |
|---|---|
| `Sources/PiAgentApp.swift` | `@main` app, toolbar, model switcher |
| `Sources/ChatView.swift` | transcript, input bar, tool badges, settings sheet |
| `Sources/ChatModel.swift` | event→state, streaming reconstruction, model list |
| `Sources/PiAgentClient.swift` | WebSocket transport + protocol decode |
| `Sources/AppSettings.swift` | host/port in UserDefaults, token in Keychain |

## Notes

- Tailscale must be running on **both** Mac and iPad, same tailnet. Inside the
  tunnel `ws://` is already encrypted; leave "Use TLS" off unless you put a
  `wss://` reverse proxy in front.
- The app only offers `ollama`/`llama-cpp`/`lmstudio`/`vllm` models, and the bridge
  rejects `set_model` for any other provider — so it stays fully local.
