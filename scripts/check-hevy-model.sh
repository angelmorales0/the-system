#!/bin/bash
#   scripts/check-hevy-model.sh            the gate: code fingerprint, current model, every replay
#   scripts/check-hevy-model.sh <config>   one config, e.g. replay-late-requests
#   scripts/check-hevy-model.sh --sync     store the fingerprint of the covered code after a review
set -euo pipefail
cd "$(dirname "$0")/.."
dir=formal/hevy-routine
version=1.7.4
sha=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
cache="${XDG_CACHE_HOME:-$HOME/.cache}/tla2tools"
jar="$cache/tla2tools-$version.jar"
java="${JAVA_HOME:+$JAVA_HOME/bin/}java"

covered() {
  awk '/static func existingRoutine\(/,/^    }$/' MyApp/Engine/HevyRoutine.swift
  awk '/static func sync\(bundle:/,/^    }$/' MyApp/Engine/HevyRoutine.swift
  awk '/private func writeHevyRoutine\(/,/^    }$/' MyApp/Engine/GameStore.swift
  grep -n 'writeHevyRoutine(' MyApp/Engine/GameStore.swift | sed 's/^[0-9]*://'
}
fingerprint() { covered | shasum -a 256 | cut -d' ' -f1; }

if [ "${1:-}" = "--sync" ]; then
  fingerprint > "$dir/covered.sha256"
  echo "Stored the fingerprint of the covered code. Move the sync commit in .claude/skills/hevy-routine-model/SKILL.md too."
  exit 0
fi

if [ ! -f "$jar" ]; then
  mkdir -p "$cache"
  curl -fsSL -o "$jar.part" "https://github.com/tlaplus/tlaplus/releases/download/v$version/tla2tools.jar"
  echo "$sha  $jar.part" | shasum -a 256 -c - >/dev/null
  mv "$jar.part" "$jar"
fi

meta="$(mktemp -d)"
trap 'rm -rf "$meta"' EXIT
tlc() {
  "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -metadir "$meta/$1" \
    -config "$dir/$1.cfg" "$dir/HevyRoutine.tla" > "$meta/$1.out" 2>&1
}

if [ -n "${1:-}" ]; then
  tlc "$1" || true
  cat "$meta/$1.out"
  exit 0
fi

failed=0
if [ "$(fingerprint)" != "$(cat "$dir/covered.sha256")" ]; then
  echo "FAIL covered code changed: HevyRoutine.sync, existingRoutine or GameStore.writeHevyRoutine."
  echo "     Follow .claude/skills/hevy-routine-model/SKILL.md, then run scripts/check-hevy-model.sh --sync."
  failed=1
fi

if tlc HevyRoutine; then
  echo "PASS HevyRoutine: the current code keeps every property."
else
  echo "FAIL HevyRoutine: the current code breaks a property. TLC says:"
  sed -n '/Error:/,$p' "$meta/HevyRoutine.out"
  failed=1
fi

replay() {
  local config=$1 property=$2 expected="Invariant $2 is violated"
  [ "$property" = EventuallyLatest ] && expected="Temporal properties were violated"
  if tlc "$config"; then
    echo "FAIL $config: the earlier code passed. The model no longer catches that bug."
    failed=1
  elif grep -q "$expected" "$meta/$config.out"; then
    echo "PASS $config: the earlier code breaks $property, as it did."
  else
    echo "FAIL $config: expected $property to break. TLC says:"
    sed -n '/Error:/,$p' "$meta/$config.out"
    failed=1
  fi
}
replay replay-75159f3 AtMostOneRoutine
replay replay-b3aa1f7-list AtMostOneRoutine
replay replay-b3aa1f7-no-id AtMostOneRoutine
replay replay-b3aa1f7-simulator OneWriteAtATime
replay replay-b3aa1f7-simulator-stays EventuallyLatest
replay replay-late-requests AtMostOneRoutine

[ "$failed" = 0 ] && echo "HEVY MODEL PASSED" || { echo "HEVY MODEL FAILED"; exit 1; }
