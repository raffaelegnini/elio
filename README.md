# Elio

Personal voice assistant for macOS, built around a warm Claude Code session (Claude Max via OAuth).

## Layout

| Path | What |
|---|---|
| `Sources/ElioApp` | Menu bar app: voice loop, status orb, dashboard, HUD, settings, IDE |
| `Sources/ElioCore` | Brain (orchestrator), ClaudeBridge (persistent `claude -p` stream-json), IntentMatcher (local fast path), LocalActions, Memory (SQLite), wire Protocol |
| `Sources/eliod` | Always-on daemon: loopback WebSocket server on `127.0.0.1:8765` |
| `Sources/elio` | Text CLI client (`elio "apri slack"` or interactive REPL) |
| `spikes/` | Phase 0 latency benchmarks — results in `docs/phase0-spike.md` |
| `scripts/` | `build-app.sh` (Elio.app), `install.sh` / `uninstall.sh` (daemon + LaunchAgent) |

## Install on your Mac (from a fork)

Everything runs on your Mac; the cloud pieces are Claude (through your own Claude Code login) and
ElevenLabs (Elio's voice).

### Requirements

- Apple Silicon Mac on **macOS 26** or later.
- **Xcode 26** (Swift 6) with its command line tools: `xcode-select --install`, then open Xcode once to accept the license.
- **Claude Code** installed and logged in with your account (Claude Pro/Max): install it from
  https://claude.com/claude-code, run `claude` once and log in. Elio looks for it in `~/.local/bin`,
  `/opt/homebrew/bin` or `/usr/local/bin`.
- An **ElevenLabs account** and its API key (https://elevenlabs.io → Profile → API keys): Elio speaks with
  ElevenLabs voices. Library voices (for example native Italian ones) need a paid plan.
- A code signing identity, so macOS remembers the microphone/calendar permissions across rebuilds.
  The free **Apple Development** certificate is enough: Xcode → Settings → Accounts → add your Apple ID →
  Manage Certificates → `+` → Apple Development. Check it with `security find-identity -v -p codesigning`.
  Without one, build with ad-hoc signing (`export ELIO_SIGN_IDENTITY=-`): it works, but macOS asks for
  permissions again after every rebuild.
- Optional: `brew install ffmpeg imagemagick` (media tools), Tailscale (phone app), a Spotify developer
  client id (search and playlists, set in Settings).

### Steps

```sh
git clone https://github.com/<you>/elio.git
cd elio
./scripts/install.sh       # builds the daemon + CLI, registers the LaunchAgent (starts at login)
./scripts/build-app.sh     # builds Elio.app into ~/Applications (downloads ONNX Runtime, Monaco, xterm.js)
open ~/Applications/Elio.app
```

On first launch:

1. Allow **Microphone** and **Speech Recognition**; later, when asked, Calendar, Reminders and control of
   other apps (Spotify, Mail…).
2. Open **Settings** (right-click the orb in the menu bar → Impostazioni…, or `⌘,`): paste the ElevenLabs
   API key (stored in the Keychain) and pick a voice, then set your name and the assistant's name. Config is saved in `~/Library/Application Support/Elio/config.json`.
3. Say "Elio…" or press `⌥⌘J` to talk. `⌥⌘D` opens the dashboard.

Check the daemon with `elio "ciao"` (the CLI is linked in `~/.local/bin`, add it to your `PATH`) or with
`tail -f ~/Library/Logs/Elio/eliod.log`.

On a MacBook with a notch the orb can end up hidden behind it when the menu bar is full: `⌘`-drag it
further right, macOS remembers the spot.

### Update and uninstall

```sh
git pull && ./scripts/install.sh && ./scripts/build-app.sh   # update
./scripts/uninstall.sh && rm -rf ~/Applications/Elio.app      # uninstall (keeps config and memory)
```

Elio can also update itself when you ask it to (the `self_update` tool runs `scripts/self-update.sh`): it runs
the tests, rebuilds and reinstalls, and puts the previous app back if anything fails.

Known limits for a fork:

- Many prompts and tool descriptions in `Sources/ElioCore` still say "Raffaele" instead of using the user name
  from the config, so Elio may call you that in places. Search and replace it before building.
- The bundle identifiers (`it.dnafactory.elio.*`) are hardcoded in the scripts; change them in
  `scripts/build-app.sh`, `scripts/install.sh` and `scripts/uninstall.sh` if you want your own.

## Run (development)

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
