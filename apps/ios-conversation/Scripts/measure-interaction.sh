#!/bin/bash
# Usage: Scripts/measure-interaction.sh <simulator-udid> [label]
# Runs InteractionPolishPerfUITests on the given simulator and prints per-phase
# frame statistics (display-link intervals; hitch = interval > 25 ms at 60 Hz).
set -euo pipefail
UDID="${1:?simulator udid}"; LABEL="${2:-run}"
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-/tmp/catpaw-interaction-dd}"; OUT="/tmp/interaction-$LABEL"; mkdir -p "$OUT"
xcodebuild -project cat.xcodeproj -scheme cat -configuration Debug -destination "id=$UDID" -derivedDataPath "$DD" \
  -only-testing:catUITests/InteractionPolishPerfUITests${ONLY_SUFFIX:-} test > "$OUT/test.log" 2>&1 || { tail -40 "$OUT/test.log"; exit 1; }
CONTAINER=$(xcrun simctl get_app_container "$UDID" com.example.cat.ConversationFirst.Auth data)
cp "$CONTAINER/Documents/interaction-probe.json" "$OUT/probe.json"
grep -o 'PHASE [a-z]* [0-9.]*' "$OUT/test.log" > "$OUT/phases.txt"
python3 - "$OUT" <<'PY'
import json,sys
out=sys.argv[1]; d=json.load(open(out+'/probe.json'))
ph=[(l.split()[1],float(l.split()[2])) for l in open(out+'/phases.txt')]
print(f"{'phase':<11}{'frames':>7}{'hitch':>7}{'hitch%':>8}{'p95ms':>7}{'maxms':>8}{'hitchms/s':>11}  counters")
for (name,a),(_,b) in zip(ph,ph[1:]):
    fr=[x[1] for x in d['frames'] if a<=x[0]<b]
    if not fr: print(f"{name:<11} no frames"); continue
    h=[x for x in fr if x>25]; s=sorted(fr)
    c={k:sum(1 for t in v if a<=t<b) for k,v in d['counters'].items()}
    print(f"{name:<11}{len(fr):>7}{len(h):>7}{100*len(h)/len(fr):>7.1f}%{s[int(.95*(len(s)-1))]:>7.1f}{max(fr):>8.1f}{sum(x-16.7 for x in h)/(b-a):>11.1f}  {c}")
PY
