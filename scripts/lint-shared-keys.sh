#!/bin/bash
# The penalty monitor is its own target, so it copies the App Group strings of PenaltyGroup.
set -uo pipefail
cd "$(dirname "$0")/.."
app=MyApp/Engine/PenaltyEnforcement.swift
monitor=PenaltyMonitor/PenaltyDeviceActivityMonitor.swift
consts() { awk -v e="enum $2 {" '$0 ~ e {on=1; next} on && /^}/ {on=0} on && /static let [A-Za-z]+ = "/ {n=$3; v=$5; print n" "v}' "$1"; }
errors=0
while read -r name value; do
  want=$(consts "$app" PenaltyGroup | awk -v n="$name" '$1==n {print $2}')
  if [ -z "$want" ]; then
    echo "ERROR: $monitor: PenaltyMonitorGroup.$name has no PenaltyGroup.$name in $app; add it there with the value $value"
    errors=$((errors + 1))
  elif [ "$want" != "$value" ]; then
    echo "ERROR: $monitor: PenaltyMonitorGroup.$name is $value but PenaltyGroup.$name is $want; use $want"
    errors=$((errors + 1))
  fi
done < <(consts "$monitor" PenaltyMonitorGroup)
[ "$errors" -eq 0 ] || { echo "LINT FAILED: shared keys"; exit 1; }
echo "LINT PASSED: shared keys"
