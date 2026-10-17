# Reply variants (regenerate / edit & resend): where they live

Status: decision record for chat-ux #1 (PR #85). Nothing here is implemented beyond what is noted.

## Current state (intentional, interim)

`ReplyVariantStore` keeps the ‹ 1/2 › grouping **on this device only**, in `UserDefaults`
(`catpaw.replyVariants.v1.<conversationID>`). This is deliberate: the Edge has no variant API, so a regenerate
or an edited resend is sent as an ordinary new turn, and only the client knows that turn B is a version of turn A.

What that means today:
- The server transcript is still complete and correct (every turn is a normal turn); the model sees the
  history the server stores, which includes the older answers.
- On another device, or after reinstall, the pager is gone: the versions show as consecutive turns.
- The data is small UUID lists (no message text), not synced, not backed by the account. It is not cleared at
  sign-out; because it has no content and keys are conversation UUIDs, a second account on the same phone
  cannot see another account's messages through it.

## Recommendation: move the grouping to the server (one field), keep the client store as a cache

1. Turn admission accepts optional `variant_of: <turn_id>` and `variant_kind: "regenerate" | "edit"`
   (validated: same conversation, the referenced turn is completed, chain depth ≤ 10).
2. The turn record and transcript echo those fields; `model_history` excludes the non-selected versions'
   answers (today they are included, which can repeat the old answer to the model).
3. Selection (`selected_variant`) stays client-side; it is a view preference.
4. iOS: `ReplyVariantStore.activate` rebuilds groups from the transcript fields when present and falls back to
   `UserDefaults` for older turns; sending sets `variant_of`.

Why not just sync the UserDefaults blob: it would need a new store and still leave the model seeing every
version. The server field fixes both and is a small contract change.

Not trivial enough to do in PR #85 (new turn fields + model-history rule + migration of the transcript shape),
so it is **not implemented** here. Small follow-up worth doing together with it: clear
`catpaw.replyVariants.v1.*` at sign-out.
