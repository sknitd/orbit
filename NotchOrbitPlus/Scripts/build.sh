#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$task_root/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'A real macOS SDK and Xcode are required to build NotchOrbitPlus.app.' >&2; exit 1; }
bash Scripts/check-sdk.sh
host_arch="$(uname -m)"
[[ "$host_arch" == arm64 || "$host_arch" == x86_64 ]] || { echo 'Unsupported macOS host architecture.' >&2; exit 1; }
ORBIT_ARCHS='arm64;x86_64' bash "$repository_root/Scripts/prepare-webp.sh"
bash Scripts/make-icon.sh
python3 Scripts/generate-project.py --check
swift test --parallel
evaluation_path="${NOTCHORBITPLUS_EVAL_DIR:-$task_root/build/evaluation}"
[[ "$evaluation_path" == /* ]] || evaluation_path="$task_root/$evaluation_path"
mkdir -p "$evaluation_path"
NOTCHORBITPLUS_EVAL_DIR="$evaluation_path" TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR="$evaluation_path" \
  NOTCHORBITPLUS_PUBLIC_PROBE_DIR="$task_root/build/public-probes" \
  TEST_RUNNER_NOTCHORBITPLUS_PUBLIC_PROBE_DIR="$task_root/build/public-probes" \
  xcodebuild -project NotchOrbitPlus.xcodeproj -scheme NotchOrbitPlus -configuration Debug \
  -destination "platform=macOS,arch=$host_arch" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project NotchOrbitPlus.xcodeproj -scheme NotchOrbitPlus -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64' build
app_path=build/DerivedData/Build/Products/Release/NotchOrbitPlus.app
executable="$app_path/Contents/MacOS/NotchOrbitPlus"
[[ -x "$executable" ]]
[[ -s "$app_path/Contents/Resources/AppIcon.icns" ]]
[[ -s "$app_path/Contents/Resources/EmojiCatalog.json" ]]
[[ -s "$app_path/Contents/Resources/ThirdParty/Unicode-LICENSE.txt" ]]
lipo "$executable" -verify_arch arm64 x86_64
mkdir -p "$app_path/Contents/Resources/ThirdParty" dist
cp "$repository_root/build/ThirdParty/libwebp-COPYING.txt" "$app_path/Contents/Resources/ThirdParty/"
cp "$repository_root/build/ThirdParty/libwebp-PATENTS.txt" "$app_path/Contents/Resources/ThirdParty/"
bash Scripts/sign-and-notarize.sh "$app_path"
file "$executable"
bash Scripts/smoke-launch.sh "$app_path"
python3 - "$app_path" <<'PY'
import json, pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.sknitd.NotchOrbitPlus' or info.get('CFBundleExecutable') != 'NotchOrbitPlus':
    raise SystemExit('The built application has the wrong product identity.')
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/NotchOrbitPlus')], text=True).split()
signing = json.loads(pathlib.Path('build/distribution-signing.json').read_text())
performance = json.loads(pathlib.Path('build/idle-performance.json').read_text())
if performance.get('outcome') != 'passed':
    raise SystemExit('The built application did not meet the measured idle-launch CPU and RSS budgets.')
if set(architectures) != {'arm64', 'x86_64'}:
    raise SystemExit('The built application is not the required universal binary.')
for architecture in architectures:
    loads = subprocess.check_output(['otool', '-arch', architecture, '-l', str(app / 'Contents/MacOS/NotchOrbitPlus')], text=True)
    foundation_loads = [block for block in loads.split('Load command ') if '/FoundationModels.framework/' in block]
    if len(foundation_loads) != 1 or 'LC_LOAD_WEAK_DYLIB' not in foundation_loads[0]:
        raise SystemExit(f'FoundationModels must be weak-linked for {architecture}.')
pathlib.Path('build/package-verification.json').write_text(json.dumps({
    'product': 'NotchOrbitPlus', 'bundle_identifier': info['CFBundleIdentifier'],
    'version': info.get('CFBundleShortVersionString'), 'architectures': sorted(architectures),
    'signature': 'Developer ID' if signing['kind'] == 'developer-id' else 'ad hoc',
    'signing_team_identifier': signing['team_identifier'], 'notarized': signing['notarized'],
    'notarization_status': signing['notarization_status'], 'codesign_verified': True, 'startup_smoke_seconds': 3,
    'foundation_models_weak_linked': True, 'minimum_macos': info.get('LSMinimumSystemVersion'),
    'idle_performance': {
        'outcome': performance['outcome'], 'warmup_seconds': performance['warmup_seconds'],
        'measurement_seconds': performance['measurement_seconds'],
        'mean_cpu_percent': performance['mean_cpu_percent'],
        'sampled_peak_rss_mb': performance['sampled_peak_rss_mb'], 'budgets': performance['budgets'],
        'evidence_file': 'idle-performance.json'
    }
}, indent=2) + '\n')
PY
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/NotchOrbitPlus.app.zip
(cd dist && shasum -a 256 NotchOrbitPlus.app.zip > NotchOrbitPlus.app.zip.sha256)
echo "Built: $task_root/$app_path"
