#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$task_root/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'A real macOS SDK and Xcode are required to build NotchOrbit.app.' >&2; exit 1; }
xcodebuild -version
host_arch="$(uname -m)"
[[ "$host_arch" == arm64 || "$host_arch" == x86_64 ]] || { echo 'Unsupported macOS host architecture.' >&2; exit 1; }
ORBIT_ARCHS='arm64;x86_64' bash "$repository_root/Scripts/prepare-webp.sh"
bash Scripts/make-icon.sh
python3 Scripts/generate-project.py --check
swift test --parallel
evaluation_path="${NOTCHORBIT_EVAL_DIR:-$task_root/build/evaluation}"
mkdir -p "$evaluation_path"
NOTCHORBIT_EVAL_DIR="$evaluation_path" TEST_RUNNER_NOTCHORBIT_EVAL_DIR="$evaluation_path" \
  xcodebuild -project NotchOrbit.xcodeproj -scheme NotchOrbit -configuration Debug \
  -destination "platform=macOS,arch=$host_arch" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project NotchOrbit.xcodeproj -scheme NotchOrbit -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64' build
app_path=build/DerivedData/Build/Products/Release/NotchOrbit.app
executable="$app_path/Contents/MacOS/NotchOrbit"
[[ -x "$executable" ]]
[[ -s "$app_path/Contents/Resources/AppIcon.icns" ]]
lipo "$executable" -verify_arch arm64 x86_64
mkdir -p "$app_path/Contents/Resources/ThirdParty" dist
cp "$repository_root/build/ThirdParty/libwebp-COPYING.txt" "$app_path/Contents/Resources/ThirdParty/"
cp "$repository_root/build/ThirdParty/libwebp-PATENTS.txt" "$app_path/Contents/Resources/ThirdParty/"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
file "$executable"
bash Scripts/smoke-launch.sh "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/NotchOrbit.app.zip
shasum -a 256 dist/NotchOrbit.app.zip > dist/NotchOrbit.app.zip.sha256
echo "Built: $task_root/$app_path"
