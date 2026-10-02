#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Launch verification requires macOS.' >&2; exit 1; }
task_app_path=${1:?Pass the compiled application bundle path}
task_executable="$task_app_path/Contents/MacOS/OrbitDrop"
[[ -x "$task_executable" ]]
mkdir -p build
"$task_executable" > build/launch-smoke.log 2>&1 &
task_app_pid=$!
trap 'kill -TERM "$task_app_pid" 2>/dev/null || true' EXIT
sleep 3
if ! kill -0 "$task_app_pid" 2>/dev/null; then
  cat build/launch-smoke.log
  echo 'Release application exited during launch verification.' >&2
  exit 1
fi
kill -TERM "$task_app_pid"
wait "$task_app_pid" || true # The expected termination signal produces a nonzero wait status.
trap - EXIT
echo 'Release launch smoke passed: application remained running for 3 seconds.'
