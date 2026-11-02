#!/bin/sh
# Writes Secrets.xcconfig (gitignored) from backend/.env, so one Xcode build seeds every connection key into the phone.
# Usage: scripts/make-secrets.sh [path/to/.env]   (default backend/.env)
set -eu
cd "$(dirname "$0")/.."
ENV_FILE="${1:-backend/.env}"
OUT="Secrets.xcconfig"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE" >&2; exit 1; }

# xcconfig reads // as a comment and $( ) as a variable: a value holding either cannot pass through.
value() {
  v=$(grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
  case "$v" in
    *//*|*'$('*) echo "$1 holds // or \$( and cannot go through xcconfig; skipped" >&2; v="" ;;
  esac
  printf '%s' "$v"
}

{
  echo "// Written by scripts/make-secrets.sh from $ENV_FILE. Gitignored. Run the script again after the env changes."
  for name in ANTHROPIC_API_KEY HEVY_API_KEY WHOOP_CLIENT_ID WHOOP_CLIENT_SECRET STRAVA_CLIENT_ID STRAVA_CLIENT_SECRET MERCURY_API_TOKEN CODEFORCES_HANDLE; do
    v=$(value "$name")
    echo "$name = $v"
    [ -n "$v" ] && echo "  $name: set" >&2 || echo "  $name: empty" >&2
  done
} > "$OUT"
echo "wrote $OUT" >&2
