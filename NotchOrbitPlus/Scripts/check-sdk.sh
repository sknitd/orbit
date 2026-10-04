#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'NotchOrbitPlus needs genuine Xcode 26+ and the macOS 26+ SDK.' >&2; exit 1; }
xcode_version="$(xcodebuild -version)"
echo "$xcode_version"
if [[ "$xcode_version" =~ Xcode[[:space:]]+([0-9]+) ]]; then
  xcode_major="${BASH_REMATCH[1]}"
else
  echo 'Cannot identify the selected Xcode version.' >&2
  exit 1
fi
(( xcode_major >= 26 )) || { echo 'Select Xcode 26 or newer; FoundationModels must be compiled into NotchOrbitPlus.' >&2; exit 1; }
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
[[ "$sdk_version" =~ ^([0-9]+) ]] || { echo 'Cannot identify the selected macOS SDK.' >&2; exit 1; }
sdk_major="${BASH_REMATCH[1]}"
(( sdk_major >= 26 )) || { echo 'A macOS 26 or newer SDK is required for FoundationModels.' >&2; exit 1; }
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$sdk_path/System/Library/Frameworks/FoundationModels.framework" ]] || { echo 'The selected SDK has no public FoundationModels framework.' >&2; exit 1; }
host_arch="$(uname -m)"
[[ "$host_arch" == arm64 || "$host_arch" == x86_64 ]] || { echo 'Unsupported macOS host architecture.' >&2; exit 1; }
mkdir -p build/sdk-probe-cache
task_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchorbitplus-sdk.XXXXXX")"
trap 'rm -rf "$task_probe_dir"' EXIT
cat > "$task_probe_dir/FoundationModelsProbe.swift" <<'SWIFT'
import FoundationModels
@available(macOS 26.0, *)
@MainActor
func foundationModelsProbe() {
    _ = SystemLanguageModel.default.availability
}
SWIFT
xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete \
  -target "$host_arch-apple-macos14.0" -sdk "$sdk_path" \
  -module-cache-path "$task_root/build/sdk-probe-cache" "$task_probe_dir/FoundationModelsProbe.swift"
swift_version="$(xcrun swiftc --version)"
python3 - "$xcode_version" "$sdk_version" "$sdk_path" "$swift_version" "$host_arch" <<'PY'
import json, pathlib, sys
pathlib.Path('build/sdk-inventory.json').write_text(json.dumps({
    'xcode': sys.argv[1], 'macos_sdk': sys.argv[2], 'sdk_path': sys.argv[3],
    'swift': sys.argv[4], 'host_architecture': sys.argv[5],
    'deployment_target': '14.0', 'foundation_models_api_typechecked': True
}, indent=2) + '\n')
PY
echo "SDK $sdk_version verified: public FoundationModels compiles with deployment target 14.0."
