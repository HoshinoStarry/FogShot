#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d)"
mount="$scratch/mount"
app="$scratch/FogShot.app"
pid=''
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  hdiutil detach "$mount" -quiet 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT

sw_vers
mkdir "$mount"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$1"
ditto "$mount/FogShot.app" "$app"
hdiutil detach "$mount" -quiet
test -x "$app/Contents/MacOS/FogShot"
codesign --verify --deep --strict --verbose=2 "$app"

launch_diagnostics() {
  log show --last 1m --style compact --predicate 'process == "FogShot" OR eventMessage CONTAINS[c] "FogShot.app"' | tail -80 || true
}
if ! open -n "$app"; then
  launch_diagnostics
  exit 1
fi

for attempt in {1..10}; do
  pid="$(pgrep -x FogShot | head -n 1 || true)"
  if [[ -n "$pid" ]]; then break; fi
  sleep 1
done
sleep 3
if [[ -z "$pid" ]] || ! kill -0 "$pid"; then
  launch_diagnostics
  echo 'FogShot did not stay running after launch.' >&2
  exit 1
fi
echo "FogShot launched and stayed running after installation from the DMG."
