# Client protocol (for the native mobile app — Flutter or Swift)

The daemon (`eliod`) is the brain. Every client — the Mac app, the phone PWA, a future native app —
talks to it over a WebSocket with one JSON object per text frame. A native app reuses exactly what the
PWA does today.

## Transport and auth

| Client | Endpoint | Auth |
|---|---|---|
| Mac app / CLI / MCP bridge | `ws://127.0.0.1:8765` | header `X-Elio-Token: <~/Library/Application Support/Elio/token>`; requests with `Origin` are rejected |
| Phone | `wss://<mac>.<tailnet>.ts.net/ws` (Tailscale serve → `127.0.0.1:8767`) | WebSocket subprotocols `["elio", "t-<remote-token>"]`; server answers `elio` |
| Phone TTS | `POST https://<mac>.<tailnet>.ts.net/tts` `{"text": "…"}` | header `X-Elio-Token: <remote-token>` → `audio/mpeg` |

Pairing: the Mac shows `https://<mac>.ts.net/#pair=<remote-token>`; the app stores the token (Keychain on iOS).
Revoking = deleting `remote-token` on the Mac (Settings → Telefono).

Remote clients may send only `say`, `ping`, `confirm`, `answer`. Tool calls and `reload` are local-only.

## Client → daemon

```json
{"type": "say", "id": "<uuid>", "text": "che impegni ho oggi?"}
{"type": "confirm", "id": "<confirm id>", "approved": true}
{"type": "answer", "id": "<question id>", "text": "usa il branch develop"}
{"type": "ping"}
```

## Daemon → client

Replies to a `say` (same `id`):

```json
{"type": "delta", "id": "…", "text": "Ha tre ", "route": "claude"}
{"type": "done",  "id": "…", "text": "<full reply>", "route": "claude|local", "latencyMs": 812}
{"type": "error", "id": "…", "text": "…"}
```

Unsolicited events: `{"type": "event", "kind": "<kind>", "id": "…", "text": "…", "payload": "<JSON string>", "speak": true}`

| kind | payload | client should |
|---|---|---|
| `reminder`, `timer`, `meeting`, `nudge`, `taskDone`, `brief`, `recap` | — / `TaskInfo` | show + speak `text` when `speak` |
| `confirm` | `ConfirmRequest {id,title,detail,risk: normal|dangerous,taskId}` | show card; dangerous needs an explicit "Confermo" |
| `confirmResolved` | `{"approved": bool}` | remove the card |
| `question` | `QuestionRequest {id,question,from,taskId}` | ask the user, reply with `answer` |
| `questionResolved` | — | remove the card |
| `task` | `TaskInfo {id,title,project,status,steps[],summary,startedAt,endedAt,kind: code|mac|squad,squad,member,role,tokensIn,tokensOut,costUSD,lastMessage}` | update workflow list |
| `taskLog` | `TaskLogEntry {taskId,kind: say|command|output|edit|write|read|search|ask|info,title,body,removed,added,date}` | live agent view |
| `diff` | `DiffPayload {title,repo,base,head,diff}` | review screen (unified diff) |
| `card` | `CardPayload {title,body (markdown)}` | detail card |
| `tool` | `{"phase":"start|end"}`, `text` = tool name, `isError`, `latencyMs` | neural activity |
| `briefStart`, `recapStart` | — | start the "neurons lighting up" animation |
| `memory` | `{"category": …}`, `text` = fact | new memory node |
| `integrationSetup` | `Integration` | open integration settings (Mac only) |
| `routineDelta` / `routineDone` | — (`text` = chunk) | briefing/recap told live: speak chunks as they arrive |
| `progress` | `{"task": "<id>"}` | spoken progress of a background agent ("Ho spostato la cartella, ora…") |
| `squad`, `squadDone` | `SquadInfo {id,goal,project,startedAt,endedAt}` | squad view (team of agents) |
| `squadMessage` | `SquadMessage {id,squad,from,to,text,at}` | squad board (`to` = member, "tutti" or "elio") |
| `usage` | `UsageSnapshot {today,window5h,elioToday: {input,output,cacheRead,cacheWrite,messages}, windowStart, agentsCostUSD}` | token usage (every minute) |
| `openView` | `{"view": "dashboard|settings|archive|squad", "tab", "integration"}` | navigate |

Dates are ISO-8601. Payload types are defined in `Sources/ElioCore/Protocol.swift`.
