#!/bin/bash
# first-run-polish: portable contrast / transition / launch-plan checks (macOS or Linux swiftc).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/first-run
cp Tests/FirstRunAppearanceRunner.swift .build/first-run/main.swift
swiftc -swift-version 5 Sources/Features/Onboarding/FirstRunAppearance.swift .build/first-run/main.swift -o .build/first-run/runner
.build/first-run/runner "$PWD"
