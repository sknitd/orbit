#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'A genuine macOS SDK and Xcode16+ are required to build CornerOrbit.app.' >&2; exit 1; }
bash Scripts/check-sdk.sh
host_arch="$(uname -m)"
[[ "$host_arch" == arm64 || "$host_arch" == x86_64 ]] || { echo 'Unsupported Mac architecture.' >&2; exit 1; }
bash Scripts/make-icon.sh
python3 Scripts/generate-project.py --check
swift test --parallel
# XCTest may forward environment variables with the TEST_RUNNER prefix.
evaluation_path="${CORNERORBIT_EVAL_DIR:-$task_root/build/evaluation}"
result_path="build/CornerOrbitTests-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$(date +%Y%m%d-%H%M%S)}.xcresult"
mkdir -p "$evaluation_path"
CORNERORBIT_EVAL_DIR="$evaluation_path" TEST_RUNNER_CORNERORBIT_EVAL_DIR="$evaluation_path" \
  xcodebuild -project CornerOrbit.xcodeproj -scheme CornerOrbit -configuration Debug \
  -destination "platform=macOS,arch=$host_arch" -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO -resultBundlePath "$result_path" \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project CornerOrbit.xcodeproj -scheme CornerOrbit -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64' build
app_path=build/DerivedData/Build/Products/Release/CornerOrbit.app
executable="$app_path/Contents/MacOS/CornerOrbit"
[[ -x "$executable" && -s "$app_path/Contents/Resources/AppIcon.icns" ]]
lipo "$executable" -verify_arch arm64 x86_64
python3 - "$executable" "$app_path/Contents/Info.plist" <<'PY'
import json, os, pathlib, plistlib, re, subprocess, sys
executable, plist = sys.argv[1:]
architectures = subprocess.check_output(['lipo', '-archs', executable], text=True).split()
if set(architectures) != {'arm64', 'x86_64'}:
    raise SystemExit('Release executable must contain exactly arm64 and x86_64.')
metadata = {'product': 'CornerOrbit', 'source_commit': os.environ.get('GITHUB_SHA'), 'architectures': architectures, 'slices': {}}
for architecture in architectures:
    detail = subprocess.check_output(['xcrun', 'vtool', '-arch', architecture, '-show-build', executable], text=True)
    match = re.search(r'^\s*minos\s+(\d+(?:\.\d+)+)\s*$', detail, re.MULTILINE)
    if not match or [int(x) for x in match[1].split('.')][:2] != [14, 0]:
        raise SystemExit(f'{architecture} does not declare macOS14.0 minimum: {detail}')
    metadata['slices'][architecture] = {'minimum_macos': match[1], 'vtool_output': detail}
with open(plist, 'rb') as stream:
    values = plistlib.load(stream)
for key, expected in {'CFBundleIdentifier': 'com.sknitd.CornerOrbit', 'CFBundleShortVersionString': '0.2.0', 'CFBundleVersion': '2', 'LSMinimumSystemVersion': '14.0', 'LSUIElement': True}.items():
    if values.get(key) != expected:
        raise SystemExit(f'Unexpected bundle metadata {key}: {values.get(key)!r}')
metadata['bundle_identifier'] = values['CFBundleIdentifier']
metadata['version'] = values['CFBundleShortVersionString']
metadata['build_number'] = values['CFBundleVersion']
pathlib.Path('build/binary-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
codesign --display --verbose=4 "$app_path" 2> build/code-signature.log
file "$executable"
bash Scripts/smoke-launch.sh "$app_path"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/CornerOrbit.app.zip
shasum -a 256 dist/CornerOrbit.app.zip | sed 's@dist/@@' > dist/CornerOrbit.app.zip.sha256
python3 - <<'PY'
import hashlib, json, os, pathlib
archive = pathlib.Path('dist/CornerOrbit.app.zip')
metadata = json.loads(pathlib.Path('build/binary-metadata.json').read_text())
metadata.update({'archive': archive.name, 'archive_bytes': archive.stat().st_size,
    'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
    'signature_kind': 'ad_hoc', 'strict_signature_verified': True, 'notarized': False,
    'smoke': json.loads(pathlib.Path('build/idle-performance.json').read_text())})
pathlib.Path('dist/package-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(f'Built genuine universal CornerOrbit.app: {archive.stat().st_size} ZIP bytes, ad hoc signed; not notarized.')
PY
