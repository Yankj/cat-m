# ask_user: human-in-the-loop controls

Status: proposal (step 1 of the ask_user track). Implementation follows one commit per control, each with server
contract tests and client fixtures. Queued after the PR #85 fixes, dictation and the voice-chat proposal.

## 1. Goal

When the model genuinely needs a fact only the user has (when, where, which one, how many, who, OK to write?), it pauses
the run and asks with a **native control**. The user's structured answer comes back as the tool result, and the run
continues in the same turn. If the model can infer the fact, it must not interrupt.

## 2. Contract: one tool, one interrupt path

`ask_user` is the input class of `render_ui`, unified with the catpaw.approval.v1 interrupt that render_ui's interactive
blocks already use (`generative-ui.mjs`: interactive blocks suspend the same turn as a `kind:'ui'` interrupt and resume
on `POST …/interrupts/{i}/decision`).

```jsonc
// tool call
{"name":"ask_user","arguments":{
  "control":"time|place|choice|number|contact|confirm_write|form",
  "id":"ask-1", "title":"约在什么时候？", "reason":"日程需要开始时间",   // reason shown small; forces the model to justify
  "params":{ /* per control, §4 */ },
  "default":{ /* recommended answer, required except contact */ },
  "allow_text":true,                                               // 「直接输入」 escape hatch (default true)
  "expires_in_sec":600
}}
// tool result after the user answers (same turn resumes)
{"status":"answered","control":"time","value":{...},"via":"control|text|default"}
{"status":"skipped"} | {"status":"expired"} | {"status":"cancelled"}
```

- **Server**: the gated registry entry `ask_user` (same offer rule as render_ui: UI contract + approval contract, plus
  `ask_user` in `X-Catpaw-UI-Kinds`). `validate` checks the schema per control. Execution suspends like a response-
  requiring render_ui block (`kind:'ui'`, `args_hash`, `expires_at`), and `uiResult` maps decisions to the result above.
- **Grounded validation is reused** (PR #85 #2, `grounded-ui.mjs`). Any option that names a real thing must cite this
  turn's tool results through `source {callId, ids}`: place candidates from `places_search`, free/busy from
  `calendar_list`, contact candidates from `contacts_search`. The server rebuilds those rows from the tool result. Ungrounded
  candidates are rejected with `ungroundedResult(code)`, so the model cannot invent a restaurant or a phone number.
- **Answer validation** on decision: the value must match the control (time within range, choice id among options, number
  within min/max, contact id among the grounded candidates). Otherwise 422 `ask_user_answer_invalid`, and the card stays open.
- **Event stream**: `ui.block` with `kind:"ask"` and `control`, then `ui.block.resolve` with the summary. Older clients
  don't advertise `ask_user`, so they never get the tool; the model falls back to asking in text.

## 3. When the model may ask (policy, appended to the system prompt)

Ask only when **all** of the following hold:
1. The fact is required to proceed.
2. It is not in the message, the history, memory, or a cheap read tool (`calendar_list`, `contacts_search`, `places_search`).
3. A wrong guess would cost the user something: a write in the wrong place, or the wrong person messaged.

Don't ask for: things with a sensible default ("明早" → 9:00, which the model states rather than asks), the user's own
city when location is available, or confirmation of a read. Ask **once per turn**, and combine several missing fields
into one `form`.
The #3 eval gains ≥ 10 ask_user cases scoring two things, should it ask and is the control right, with a bar of ≥ 85% over 3 runs.

## 4. Controls (one commit each)

| # | control | params | iOS | Grounding |
|---|---|---|---|---|
| 1 | `time` | `mode: date\|time\|datetime`, `range`, `quick:[{label,value}]` (今晚 / 明早 9 点), `busy_from:callId` | DatePicker (graphical/compact) + quick chips; busy slots greyed from calendar_list | busy/free from `calendar_list` result |
| 2 | `place` | `allow_current`, `recent:true`, `search_hint` | Map with draggable pin, search field (MKLocalSearch), recent places, 「当前位置」 | candidates via `places_search` source |
| 3 | `choice` | `multi`, `options:[{id,label,image?}]` or `source`, `other:true` | Chips; or image cards (place card + 「选这家」); 「其他」 opens a text field | place/event options grounded |
| 4 | `number` | `min,max,step,unit`, `style: stepper\|slider`, `range:true` | Stepper or Slider (two thumbs for a range) | — |
| 5 | `contact` | `source:{callId,ids}` | Avatar, name, **masked number** (138****1234), per #7 minimal fields | required: `contacts_search` result |
| 6 | `confirm_write` | `tool`, `args`, `editable:[keys]`, `destructive` | Card with inline-editable fields; destructive → red primary button; success haptic | args from the pending device_call |
| 7 | `form` | `fields:[{key,label,type,default,required,pattern}]` (≤ 6) | Short sheet with defaults and inline validation | — |

`confirm_write` is not a new approval mechanism. It is the existing device_call confirm card, extended with inline edits.
The edited args go back as the answer, and the server re-hashes them (`args_hash`) before the write runs.

## 5. Applies to every control

- **A recommended default** is pre-selected. One tap 「用推荐」 answers with `via:"default"`.
- **Skip** (「跳过」) returns `skipped`, and the model proceeds with its stated assumption or asks in text. **「直接输入」**
  switches to the composer, and the typed text returns as `via:"text"`.
- **After submit**, the card collapses to a read-only summary row (「时间：明天 09:00」) that stays in history (journal + transcript).
- **Survives restart**: pending asks are restored from `pendingUIApprovals` (as for render_ui). Past `expires_at`, the card
  shows 「已过期」 and the server resolves it `expired`.
- **Accessibility**: dark mode tokens, Dynamic Type up to AX5 (controls stack vertically), and VoiceOver labels with
  rotor actions for quick picks. Holding or dragging is never required (the pin has a 「用当前位置」 / search alternative).

## 6. Rollout

Server first (tool gated by the kinds header, with contract tests and fixtures `catpaw-ask-user.json` mirrored one-to-one in
`NoBugP0Runner`). Then the iOS controls in the order above. CI green is the gate for every commit, and screenshots wait for the Mac.
