#!/bin/bash
# A wall-clock time on a quest day is never the day's start plus seconds: on a clock-change day that is an hour off.
set -uo pipefail
cd "$(dirname "$0")/.."
hits=$(grep -rnE '(QuestDay\.start\(of: [^)]*\)\??|dayStart)\.addingTimeInterval\(' --include='*.swift' \
  MyApp PenaltyMonitor PenaltyActivity PenaltyShieldAction PenaltyShieldConfig SharedWidgets FocusTracker)
if [ -n "$hits" ]; then
  while IFS= read -r hit; do
    echo "ERROR: ${hit%%:*}:$(echo "$hit" | cut -d: -f2): a time on a quest day is not its start plus seconds; use QuestDay.time(on:minutes:)"
  done <<< "$hits"
  echo "LINT FAILED: day math"
  exit 1
fi
echo "LINT PASSED: day math"
