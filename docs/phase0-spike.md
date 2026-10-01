# Phase 0 — Spike results (2026-10-01, MacBook M4 16GB, macOS 26.5)

| Component | Setup | Result |
|---|---|---|
| Claude cold | `claude -p` per request | ~5.5–6.5s total — unusable for voice |
| Claude warm | persistent `--input-format stream-json`, Sonnet, no tools, project settings only | **TTFT ~0.85s**, ~2.4s full short answer (boot ~2.7s once) |
| Claude warm | same, Haiku | TTFT ~2.0s (slower than Sonnet in this run) |
| Router (Apple FM) | structured `Decision{route, ack}` | 0.7–2.0s, 8/9 correct, acks low quality / invent facts |
| Router (Apple FM) | route-only enum, prewarm, greedy | ~0.4s, 8/12 correct (claude vs agent confusion) |
| STT | SpeechAnalyzer `it_IT`, on-device | 5.2s audio → final text in 0.5s, first partial 0.31s, near-perfect |
| TTS | ElevenLabs Flash/Turbo v2.5 stream, voices Daniel/George | **TTFB ~0.35–0.4s** warm (1.1s cold connection), 94 chars |

## Decisions
- Claude Sonnet warm session = conversational brain. Process kept alive by daemon, respawned on crash.
- Local fast path = deterministic intent matcher (open app, timer, volume, time, reminders) → 0ms, 0 tokens.
  Apple FM only as fuzzy fallback for local intent/slot extraction, never for user-facing facts.
- Agent escalation decided by Claude itself (tool `start_background_task`), not by local router.
- Acks = pre-generated cached audio clips chosen by route, not generated text.
- `--setting-sources project` keeps user hooks/plugins out of Jarvis's Claude session.

## Estimated voice round-trip
end of speech → STT final ~0.3s → Claude TTFT ~0.85s → first sentence buffered → TTS TTFB ~0.4s ≈ **1.6–2s** to first audio.
Keep one HTTP/WebSocket connection to ElevenLabs warm to avoid ~0.7s cold penalty.

## Secrets
ElevenLabs key in macOS Keychain: service `jarvis-elevenlabs`, account `jarvis`.
