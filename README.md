# Jarvis

Personal voice assistant for macOS, built around a warm Claude Code session (Claude Max via OAuth).

## Layout

| Path | What |
|---|---|
| `Sources/JarvisCore` | Brain (orchestrator), ClaudeBridge (persistent `claude -p` stream-json), IntentMatcher (local fast path), LocalActions, Memory (SQLite), wire Protocol |
| `Sources/jarvisd` | Always-on daemon: loopback WebSocket server on `127.0.0.1:8765` |
| `Sources/jarvis` | Text CLI client (`jarvis "apri slack"` or interactive REPL) |
| `spikes/` | Phase 0 latency benchmarks — results in `docs/phase0-spike.md` |
| `scripts/` | `install.sh` / `uninstall.sh` for the LaunchAgent |

## Run

```sh
swift build && .build/debug/jarvisd      # dev, foreground
./scripts/install.sh                     # release + LaunchAgent (starts at login)
jarvis                                   # REPL client
```

## Runtime files

- Config: `~/Library/Application Support/Jarvis/config.json` (user name, model, port, voice)
- Memory: `~/Library/Application Support/Jarvis/jarvis.sqlite`
- Client token: `~/Library/Application Support/Jarvis/token` (0600)
- Claude session workspace: `~/Library/Application Support/Jarvis/workspace`
- Logs: `~/Library/Logs/Jarvis/jarvisd.log`
- ElevenLabs key: Keychain, service `jarvis-elevenlabs`

## Security model

- Server binds loopback only and requires `X-Jarvis-Token`; requests with an `Origin` header
  (web pages) are rejected, so a browser tab cannot drive Jarvis.
- The Claude session runs with no tools yet. From Phase 4, push / merge / sending messages /
  deleting files go through an explicit confirmation gate enforced in code, not in the prompt.
