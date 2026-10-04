#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'This probe requires a genuine macOS runtime.' >&2; exit 2; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
report_root="${1:-$task_root/build/plugin-sandbox-probe}"
mkdir -p "$report_root"
report_root="$(cd "$report_root" && pwd)"
probe_workspace="$(mktemp -d "$report_root/.probe-XXXXXX")"
trap 'rm -rf "$probe_workspace"' EXIT
python3 - "$task_root" "$probe_workspace" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
source = root / 'Sources/NotchOrbitPlus/Tools/Plugins/PluginSandbox.swift'
# Compile the exact production implementation next to its actual Core model;
# only remove the module import because these two files form the probe module.
(destination / 'PluginSandbox.swift').write_text('\n'.join(
    line for line in source.read_text().splitlines() if line != 'import NotchCore') + '\n')
PY
{
    sw_vers
    xcrun swiftc --version
    ls -l /bin/sh
    file /bin/sh
    readlink /bin/sh || true
} > "$report_root/runtime.txt" 2>&1
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" -sdk "$sdk_path" \
    -module-cache-path "$probe_workspace/module-cache" \
    "$task_root/Sources/NotchCore/CorePlugins.swift" \
    "$probe_workspace/PluginSandbox.swift" "$task_root/Scripts/PluginSandboxProbe.swift" \
    -o "$probe_workspace/plugin-probe" > "$report_root/compile.log" 2>&1
"$probe_workspace/plugin-probe" "$report_root"
