#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'A macOS session is required for the NotchOrbitPlus launch smoke check.' >&2; exit 1; }
app_path="${1:?Pass the path to NotchOrbitPlus.app}"
executable="$app_path/Contents/MacOS/NotchOrbitPlus"
[[ -x "$executable" ]] || { echo 'The NotchOrbitPlus executable is missing.' >&2; exit 1; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
log_path="$task_root/build/launch-smoke.log"
app_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
"$executable" >"$log_path" 2>&1 &
app_pid=$!
sleep 3
if ! kill -0 "$app_pid" 2>/dev/null; then
  cat "$log_path" >&2
  echo 'NotchOrbitPlus exited during the 3-second startup smoke check.' >&2
  exit 1
fi
echo 'NotchOrbitPlus stayed running for the 3-second startup smoke check.' | tee -a "$log_path"
