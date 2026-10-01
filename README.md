# Elio

Personal voice assistant for macOS, built around a warm Claude Code session (Claude Max via OAuth).

## Layout

| Path | What |
|---|---|
| `Sources/ElioCore` | Brain (orchestrator), ClaudeBridge (persistent `claude -p` stream-json), IntentMatcher (local fast path), LocalActions, Memory (SQLite), wire Protocol |
| `Sources/eliod` | Always-on daemon: loopback WebSocket server on `127.0.0.1:8765` |
| `Sources/elio` | Text CLI client (`elio "apri slack"` or interactive REPL) |
| `spikes/` | Phase 0 latency benchmarks — results in `docs/phase0-spike.md` |
| `scripts/` | `install.sh` / `uninstall.sh` for the LaunchAgent |

## Run

```sh
swift build && .build/debug/eliod      # dev, foreground
./scripts/install.sh                     # release + LaunchAgent (starts at login)
elio                                   # REPL client
```

## Runtime files

- Config: `~/Library/Application Support/Elio/config.json` (user name, model, port, voice)
- Memory: `~/Library/Application Support/Elio/elio.sqlite`
- Client token: `~/Library/Application Support/Elio/token` (0600)
- Claude session workspace: `~/Library/Application Support/Elio/workspace`
- Logs: `~/Library/Logs/Elio/eliod.log`
- ElevenLabs key: Keychain, service `elio-elevenlabs`

## Security model

- Server binds loopback only and requires `X-Elio-Token`; requests with an `Origin` header
  (web pages) are rejected, so a browser tab cannot drive Elio.
- The Claude session runs with no tools yet. From Phase 4, push / merge / sending messages /
  deleting files go through an explicit confirmation gate enforced in code, not in the prompt.
