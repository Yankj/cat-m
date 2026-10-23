# Voice chat (demo grade) on Gemini Live, free tier

Status: proposal only. Nothing is implemented or deployed. Scope: a **demo build**, not production. It comes after the
dictation fix (PR #85) and before ask_user.

## 1. Demo scenarios (definition of done)

| # | Scenario | What the audience sees |
|---|---|---|
| D1 | Natural chat | Speak, and cat answers by voice in about a second. Captions for both sides. |
| D2 | Barge-in | Talk over a long answer. Playback stops at once and the new question is answered. |
| D3 | Captions | Live captions for the user (input transcription) and for cat (output transcription), kept in the transcript afterwards. |
| D4 | "明天上午十点加个牙医日程" | The model calls `calendar_create`. The existing device_call confirm card appears, and the voice says 「确认一下」. Tap 执行, and the receipt (with 撤销) shows. |
| D5 | "附近有什么好吃的" | The model calls `places_search`. The phone runs it and the server auto-emits the grounded **place card** (PR #85 #2), and the voice reads the top two. |
| D6 | Quota runs out | A friendly line: 「今天的语音额度用完了，先用打字或听写吧」. The chat stays usable by text and dictation. |

Device: the user's iPhone 13 on iOS 26.

## 2. Architecture

```
iPhone ──WSS (audio PCM16 16 kHz up / 24 kHz down, JSON events)──▶ Supabase Edge relay ──WSS──▶ Gemini Live (Flash Live)
   ▲                                                                   │
   └──────── device_call / approval events (same as chat) ◀────────────┘  tool calls bridged to the chat service
```

**Why a relay.** An iPhone in mainland China cannot reach `generativelanguage.googleapis.com`, so ephemeral tokens alone
(phone → Gemini) don't help. The relay holds the Gemini API key, opens the upstream socket, and forwards frames.
For a future deployment outside China, the same relay can instead mint an **ephemeral token** (Live API only; one use;
by default a new session must start within 60 s and messages are accepted for 30 min) and let the phone connect
directly. [Gemini ephemeral tokens](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens)

### 2.1 Can a Supabase Edge Function hold a long WebSocket?

Partly. The key limits, from the Supabase docs:
- Inbound WebSocket servers are supported (`Deno.upgradeWebSocket`), and so are outbound WebSockets. [Handling WebSockets](https://supabase.com/docs/guides/functions/websockets)
- **Wall-clock limit per worker: 150 s on Free, 400 s on paid plans.** The worker shuts down at the limit, and this is not
  configurable on hosted Supabase. [Limits](https://supabase.com/docs/guides/functions/limits),
  [wall clock troubleshooting](https://supabase.com/docs/guides/troubleshooting/edge-function-wall-clock-time-limit-reached-Nk38bW)
- The worker can be retired **early** (`EarlyDrop`) once the 101 response is returned, unless an `EdgeRuntime.waitUntil`
  promise stays pending until the socket closes. `waitUntil` does not extend the hard limit.
  [Worker timeouts and WebSocket drops](https://supabase.com/docs/guides/troubleshooting/edge-functions-worker-timeouts-and-websocket-drops)
- CPU 2 s per request. Frame forwarding is I/O, but base64 audio re-encoding counts against it, so forward binary/JSON as-is.

Gemini's side: a connection lives about 10 min, and an audio-only session 15 min without compression. **Session resumption**
lets a session span several connections (handles stay valid 2 h). **Context window compression** removes the 15-min cap.
[Session management](https://ai.google.dev/gemini-api/docs/live-api/session-management)

**Design for "one stable session".** The relay is stateless per connection. Each upstream connect sets
`sessionResumption` and keeps the latest `SessionResumptionUpdate.handle`, which it forwards to the phone. Before the Edge
limit (we use 120 s on Free, 360 s on paid), the relay sends `{"type":"reconnect"}`. The phone opens a new relay socket
with the handle, the relay resumes the same Gemini session, and audio continues. Expect a gap of roughly 150–300 ms,
hidden by buffering, and only between turns (the phone waits for `turnComplete` or silence before switching).
To the user it is one session. `contextWindowCompression` (sliding window) is on, so the 15-min audio cap doesn't apply.

If that reconnect proves too visible in the demo, the fallback is the same relay code on a small VM in Hong Kong
(no wall-clock cap). The relay is ~150 lines of Deno, so it runs there unchanged.

### 2.2 Latency, measurement plan (no deploy allowed now)

From this box: TLS to `generativelanguage.googleapis.com` took ~0.10 s and first byte ~0.17 s (5 samples, 2026-10-16).
**Not representative**: the box egresses through a proxy (TCP connect reads 1 ms), and it is neither in the Edge region
nor in China.

Plan, once deploying a probe is approved:
1. Deploy `voice-relay-probe` (no key needed) that opens a TCP+TLS connection to `generativelanguage.googleapis.com:443`
   20× and returns p50/p95 handshake times. Call it from the phone too, to get phone↔Edge RTT.
2. With the key in Edge secrets: open a Live session, send 1 s of silence then a 2 s recorded question, and measure
   **time from end of speech to first audio byte**. Repeat 20× for each region the project could use.
3. Targets for the demo: phone↔Edge RTT < 120 ms, end-of-speech → first audio < 1.2 s p50. Above that, use the HK VM.

## 3. Function calling: reuse device_call and approval

Gemini Live supports tool declarations in `setup` and `toolCall` / `toolResponse` messages. The relay offers the **same
tool definitions** the chat service builds (`chatToolsFor` with the device and UI contracts; demo subset:
`calendar_create`, `reminder_create`, `places_search`, `calendar_list`, `render_ui`):
- On `toolCall`, the relay calls the chat service's existing device path (the same validation, `args_hash`, approval
  class and `device_call` event). The phone shows the **same confirm card** and runs EventKit / MapKit. Its
  `device-result` is turned into the Live `toolResponse`. Undo (PR #85 #6) works unchanged.
- `places_search` results go through grounded UI (`autoPlaceBlock`), so the place card is the server-built one. The
  model only speaks a summary.
- While a confirm card is open, the relay sends Gemini nothing new, and the voice says 「请在卡片上确认」. If the call
  isn't confirmed within 60 s, the relay sends `toolResponse {status:"cancelled"}`.
- The transcript (captions plus tool events) is saved as a normal conversation turn, so it shows in history.

## 4. Barge-in, echo cancellation, captions

- **Echo cancellation**: `AVAudioSession` `.playAndRecord` with mode `.voiceChat`, so iOS voice processing (AEC/AGC/NS)
  runs. Use `AVAudioEngine` with `inputNode.setVoiceProcessingEnabled(true)`. Without this the model hears itself.
- **Barge-in**: Gemini's server-side VAD sends `interrupted` when the user talks over a reply. The phone then flushes its
  playback queue at once (`AVAudioPlayerNode.stop()` and drop queued buffers). We do no local VAD in the demo.
- **Captions**: turn on `inputAudioTranscription` and `outputAudioTranscription` in setup. Show them as two live caption
  rows that become normal chat bubbles at `turnComplete`.

## 5. Fallback when quota or concurrency runs out

Free-tier limits as given: about 3 concurrent sessions and about 15 min per audio session.
- If the relay gets 429 / RESOURCE_EXHAUSTED from upstream, or `goAway` with a quota reason, it sends
  `{"type":"quota"}`.
- The phone shows: 「今天的语音额度用完了，先用打字或听写吧」, closes voice mode, and focuses the composer with dictation ready.
- Optional for the demo, if time allows: degraded voice. Use local dictation (the fixed composer dictation), then the
  current chat LLM, then `AVSpeechSynthesizer` reads the reply aloud. That reuses existing pieces, but it is a second mode to test, so it is not in the base estimate.

## 6. Privacy notice (free tier)

The free tier's data **is used to improve Google's products**. Before the first voice session, show a one-time sheet:
> 语音对话（演示版）使用 Google Gemini 免费额度。你的语音和对话内容会发送到 Google，并可能被用于改进其产品。不要在语音对话中说敏感信息。[我知道了] [不用了]

Store consent per account, and add a "语音对话（演示）" toggle in Settings › 隐私. No further compliance work for the demo.

## 7. Backup option: OpenAI gpt-realtime

| | Gemini Live (Flash Live) | OpenAI gpt-realtime |
|---|---|---|
| Cost | Free tier (demo fits) | No free tier, paid per audio token |
| Reach from China | Needs relay | Needs relay |
| Tools / barge-in / transcription | Yes / server VAD / in & out | Yes / server VAD / in & out |
| Session limits | Connection ~10 min, resumable; 15 min audio without compression | Session cap ~30–60 min (verify against current OpenAI docs before choosing) |
| Relay example on Edge | Same pattern | Supabase's own blog example relays OpenAI Realtime from an Edge Function |

Keep the relay's upstream behind a small adapter (`setup`, `audioIn`, `audioOut`, `toolCall`, `interrupted`, `transcript`)
so switching providers is a config change. gpt-realtime stays a backup only.

## 8. Effort (demo grade, one engineer)

| Piece | Days |
|---|---|
| Edge relay: upgrade, upstream connect, resumption handles, timed reconnect, quota mapping, waitUntil | 2 |
| Tool bridge to the existing device_call / approval / grounded place path (+ contract tests) | 2 |
| iOS voice mode: audio engine with voice processing, PCM up/down, playback queue + barge-in flush, reconnect handling | 3 |
| Captions UI + transcript saved as a turn, quota message, privacy sheet + setting | 1.5 |
| Latency probe + on-device tuning on the iPhone 13 (D1–D6 walkthrough) | 1.5 |
| **Total** | **≈ 10 working days** (2 weeks), +2 days if the HK VM fallback or the degraded voice mode is needed |

Risks: the Edge 150 s cap (mitigated by resumption reconnects, or by a paid plan's 400 s, or the HK VM), free-tier limits
changing, and AEC quality on the iPhone speaker (test early; headphones make the demo easier).
