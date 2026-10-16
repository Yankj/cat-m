# feat/reply-chrome

Structure/rhythm from `docs/refs/grok-reply/` (light theme kept; no dark borrow).

| Stage | Surface |
|---|---|
| Waiting | `ThinkingHeader.liveRow` — presence + 「思考中 · Ns」 |
| In progress | `ReplyStepRow` + `SourceCapsuleStrip` under the live line |
| Streaming | `FadingStreamText` on background (no bubble); composer stop morph already in `ComposerChrome` (Mac worker) |
| Done | 「思考结果 ›」 chip; `ReplyActionRow` (last reply only, #60 + pager); optional `FollowUpList` hook |

Hooks not wired to a backend yet: `generationSeconds` trailing time, `followUps` / `onFollowUp`, thumbs feedback sink.
