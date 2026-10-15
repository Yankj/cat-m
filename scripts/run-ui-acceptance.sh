#!/usr/bin/env bash
# One-click XCUITest acceptance: builds CatpawM, runs CatpawAcceptanceUITests on a Simulator,
# exports every keepAlways screenshot from the .xcresult and writes an HTML + Markdown report.
#   scripts/run-ui-acceptance.sh                     # offline fixture cases only
#   CATPAW_ACCEPTANCE_LIVE=1 scripts/run-ui-acceptance.sh   # also real anonymous sign-in
#   SIM_NAME="iPhone 17 Pro" OUT=build/ui-acceptance scripts/run-ui-acceptance.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/apps/ios-conversation/CatpawM.xcodeproj"
SCHEME="${SCHEME:-CatpawM}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$ROOT/build/ui-acceptance/$STAMP}"
RESULT="$OUT/Acceptance.xcresult"
mkdir -p "$OUT"

DEST="${DESTINATION:-platform=iOS Simulator,name=$SIM_NAME}"
echo "▶ xcodebuild test → $DEST"
set +e
TEST_RUNNER_CATPAW_ACCEPTANCE_LIVE="${CATPAW_ACCEPTANCE_LIVE:-0}" \
xcodebuild test \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DEST" \
  -only-testing:CatpawMUITests/CatpawAcceptanceUITests \
  -resultBundlePath "$RESULT" \
  -derivedDataPath "$OUT/DerivedData" \
  2>&1 | tee "$OUT/xcodebuild.log" | grep -E "Test Case|error:|\*\* TEST" || true
STATUS=${PIPESTATUS[0]}
set -e
[[ -d "$RESULT" ]] || { echo "✗ no result bundle (build failed?) — see $OUT/xcodebuild.log"; exit 1; }

echo "▶ exporting attachments"
SHOTS="$OUT/screenshots"; mkdir -p "$SHOTS"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS" >/dev/null
xcrun xcresulttool get test-results tests --path "$RESULT" > "$OUT/tests.json" || true

/usr/bin/python3 - "$OUT" <<'PY'
import json,sys,html,os
out=sys.argv[1];shots=os.path.join(out,"screenshots")
manifest=json.load(open(os.path.join(shots,"manifest.json")))
results={}
try:
    def walk(n):
        if n.get("nodeType")=="Test Case": results[n.get("nodeIdentifier") or n["name"]]=n.get("result","?")
        for c in n.get("children",[]): walk(c)
    for n in json.load(open(os.path.join(out,"tests.json"))).get("testNodes",[]): walk(n)
except Exception: pass
rows=[]
for t in manifest:
    tid=t.get("testIdentifier","?")
    status=next((v for k,v in results.items() if k.endswith(tid.split("/")[-1].replace("()",""))) or k==tid),"?")
    for a in sorted(t.get("attachments",[]),key=lambda a:a.get("suggestedHumanReadableName","")):
        rows.append((tid,status,a.get("suggestedHumanReadableName",""),a["exportedFileName"]))
md=["# Catpaw UI acceptance report","",f"Result bundle: `{os.path.join(out,'Acceptance.xcresult')}`",""]
h=["<html><meta charset=utf-8><title>Catpaw UI acceptance</title><style>body{font-family:-apple-system;margin:24px}figure{display:inline-block;margin:8px;width:260px;vertical-align:top}img{width:100%;border:1px solid #ccc;border-radius:12px}.Passed{color:green}.Failed{color:#c00}.Skipped,.Expected\\ Failure{color:#a60}</style><h1>Catpaw UI acceptance</h1>"]
cur=None
for tid,st,name,f in rows:
    if tid!=cur:
        cur=tid;md+=["",f"## {tid} — {st}",""];h.append(f"<h2>{html.escape(tid)} — <span class='{st}'>{st}</span></h2>")
    md.append(f"![{name}](screenshots/{f})  `{name}`")
    h.append(f"<figure><img src='screenshots/{html.escape(f)}'><figcaption>{html.escape(name)}</figcaption></figure>")
for k,v in results.items():
    if not any(k.endswith(r[0].split('/')[-1].replace('()','')) for r in rows): md.append(f"\n## {k} — {v} (no screenshots)");h.append(f"<h2>{html.escape(k)} — {v} (no screenshots)</h2>")
open(os.path.join(out,"report.md"),"w").write("\n".join(md)+"\n")
open(os.path.join(out,"report.html"),"w").write("\n".join(h))
print(f"✓ {len(rows)} screenshots → {out}/report.html")
PY
echo "xcodebuild exit: $STATUS"
command -v open >/dev/null && open "$OUT/report.html" || true
exit "$STATUS"
