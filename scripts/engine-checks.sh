#!/bin/bash
# Compiles the engine as a macOS program and runs every EngineChecks suite.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/engine-checks"
mkdir -p "$out"
swiftc -Onone -default-isolation MainActor -module-name Harness \
  MyApp/Engine/*.swift MyApp/Models/*.swift \
  MyApp/HomeTracker.swift MyApp/WidgetBridge.swift SharedWidgets/WidgetData.swift \
  scripts/engine-checks/main.swift -o "$out/run" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker MyApp-Info.plist
cp MyApp/Resources/FallbackCatalog.json "$out/"
"$out/run"
