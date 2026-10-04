#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'CornerOrbit requires a genuine macOS SDK and Xcode16+.' >&2; exit 1; }
xcode_version="$(xcodebuild -version)"
echo "$xcode_version"
[[ "$xcode_version" =~ Xcode[[:space:]]+([0-9]+) ]] || { echo 'Cannot identify the selected Xcode version.' >&2; exit 1; }
(( BASH_REMATCH[1] >= 16 )) || { echo 'Select Xcode16 or newer for Swift6.' >&2; exit 1; }
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
mkdir -p build/sdk-probe-cache
task_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cornerorbit-sdk.XXXXXX")"
trap 'rm -rf "$task_probe_dir"' EXIT
cat > "$task_probe_dir/CornerSDKProbe.swift" <<'SWIFT'
import AppKit
import SwiftUI
import Foundation
@MainActor
func cornerSDKProbe() {
    _ = NSStatusBar.system
    _ = NSWorkspace.shared
    _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    _ = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
}
SWIFT
for architecture in arm64 x86_64; do
  xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete \
    -target "$architecture-apple-macos14.0" -sdk "$sdk_path" \
    -module-cache-path "$task_root/build/sdk-probe-cache" "$task_probe_dir/CornerSDKProbe.swift"
done
python3 - "$xcode_version" "$sdk_version" "$(xcrun swiftc --version)" <<'PY'
import json, pathlib, sys
pathlib.Path('build/sdk-inventory.json').write_text(json.dumps({
    'xcode': sys.argv[1], 'macos_sdk': sys.argv[2], 'swift': sys.argv[3],
    'deployment_target': '14.0', 'probe_architectures': ['arm64', 'x86_64'],
    'public_appkit_swiftui_automation_apis_typechecked': True
}, indent=2) + '\n')
PY
