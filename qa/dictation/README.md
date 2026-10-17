# Dictation corpus + WER/CER harness

For device runs (iPhone 13, iOS 26); nothing here runs on CI except the scorer's own unit test.

1. Build the branch to the phone. In the composer, dictate each sentence in `corpus.json` (s19 has a 2 s pause at the
   marked spot; s20 runs past one minute to check auto-continue). Do it once by **tap** (tap mic, speak, tap ✓) and once
   by **hold** (press and hold, release).
2. Copy what landed in the draft into `runs/<date>-<tier>-<mode>-<noise>.json` (format at the top of `score.mjs`). The
   engine tier is shown in debug logs (`NativeVoiceController.dictationTier`).
3. `node qa/dictation/score.mjs qa/dictation/runs/<file>.json`. This prints CER/WER per sentence and in total.

Also check by hand on each run:
- **Cancel restores the draft.** Type "草稿", dictate, then ✕ (or slide left while holding). The draft must be exactly "草稿" again.
- **Pause.** On s19 the text before the pause stays put.
- **Route change.** Connect or disconnect AirPods while dictating. Dictation continues and the text so far stays.
- **Long dictation (s20).** Text keeps arriving after 60 s, with no cut at one minute.

Scoring: CER is over characters, with punctuation, spaces and case removed. WER uses whitespace tokens for English and
one token per Han character for Chinese, so WER equals CER for Chinese. `punctuated` counts results that contain any punctuation.
