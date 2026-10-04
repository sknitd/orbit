#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'This probe requires a genuine macOS runtime.' >&2; exit 2; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
report_root="${1:-$task_root/build/compact-accessibility-probe}"
mkdir -p "$report_root"
report_root="$(cd "$report_root" && pwd)"
probe_workspace="$(mktemp -d "$report_root/.probe-XXXXXX")"
trap 'rm -rf "$probe_workspace"' EXIT
python3 - "$task_root" "$probe_workspace" "$report_root" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
root, temporary, report = map(Path, sys.argv[1:])
production = root / 'Sources/NotchOrbitPlus/Dashboard/LiveCompactView.swift'
fixture = root / 'Tests/NotchOrbitPlusTests/ExpandedCompactEvaluationTests.swift'
sources = [production, fixture, root / 'Scripts/CompactAccessibilityProbe.swift']
tail = production.read_text().split('@MainActor\nstruct LiveCompactContent: View {', 1)
if len(tail) != 2:
    raise SystemExit('Exact production compact view marker is missing.')
fragment = 'import AppKit\nimport SwiftUI\nimport NotchCore\n@MainActor\nstruct LiveCompactContent: View {' + tail[1]
(temporary / 'LiveCompactContent.swift').write_text(fragment)
helper = fixture.read_text().split('@MainActor\nenum CompactAccessibilityFixture {', 1)
if len(helper) != 2:
    raise SystemExit('Exact native accessibility fixture helper is missing.')
(temporary / 'CompactAccessibilityFixture.swift').write_text(
    'import AppKit\nimport ObjectiveC\n@MainActor\nenum CompactAccessibilityFixture {' + helper[1])
commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
inventory = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
inventory.update({str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in sorted((root / 'Sources/NotchCore').glob('*.swift'))})
(report / 'provenance.json').write_text(json.dumps({'source_commit': commit, 'source_sha256': inventory,
    'production_fragment_sha256': hashlib.sha256(fragment.encode()).hexdigest(),
    'scope': 'Owned-window synthetic Copy/Reveal fixtures; no TCC, accounts, user clipboard or Finder actions.'}, indent=2) + '\n')
PY
{
    sw_vers
    xcrun swiftc --version
} > "$report_root/runtime.txt" 2>&1
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
{
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -sdk "$sdk_path" \
        -module-cache-path "$probe_workspace/module-cache" -module-name NotchCore \
        -emit-library -emit-module -emit-module-path "$probe_workspace/NotchCore.swiftmodule" \
        "$task_root"/Sources/NotchCore/*.swift -o "$probe_workspace/libNotchCore.dylib"
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -sdk "$sdk_path" \
        -module-cache-path "$probe_workspace/module-cache" -I "$probe_workspace" -L "$probe_workspace" -lNotchCore \
        -Xlinker -rpath -Xlinker "$probe_workspace" \
        "$probe_workspace/LiveCompactContent.swift" "$probe_workspace/CompactAccessibilityFixture.swift" \
        "$task_root/Scripts/CompactAccessibilityProbe.swift" -o "$probe_workspace/compact-probe"
} > "$report_root/compile.log" 2>&1
"$probe_workspace/compact-probe" "$report_root" > "$report_root/runtime.log" 2>&1
