#!/usr/bin/env bash
# Codex PR90 proactive portable tests (pure rules/ledgers/queue; no UIKit/EventKit). Runs on macOS and Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/proactive-pr90
swiftc -parse-as-library -swift-version 5 \
  Sources/Features/Proactive/ProactiveRules.swift Sources/Features/Proactive/ProactiveQuota.swift Sources/Features/Proactive/ProactiveAccountGate.swift Sources/Features/Proactive/ProactiveDeliveryPipeline.swift Sources/Domain/AccountEpoch.swift Sources/Domain/CatpawPersistentQueue.swift \
  Tests/ProactivePortableShims.swift Tests/ProactivePR90Runner.swift -o .build/proactive-pr90/runner
.build/proactive-pr90/runner
