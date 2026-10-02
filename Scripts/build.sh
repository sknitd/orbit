#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'A real macOS SDK and Xcode are required; this script cannot build a native .app on Linux.' >&2; exit 1; }
xcodebuild -version
bash Scripts/prepare-webp.sh
bash Scripts/make-icon.sh
python3 Scripts/generate-project.py --check
swift test --parallel
xcodebuild -project OrbitDrop.xcodeproj -scheme OrbitDrop -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
xcodebuild -project OrbitDrop.xcodeproj -scheme OrbitDrop -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
app_path=build/DerivedData/Build/Products/Release/OrbitDrop.app
[[ -x "$app_path/Contents/MacOS/OrbitDrop" ]]
cp build/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
mkdir -p "$app_path/Contents/Resources/ThirdParty" dist
cp build/ThirdParty/* "$app_path/Contents/Resources/ThirdParty/"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
file "$app_path/Contents/MacOS/OrbitDrop"
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/OrbitDrop.app.zip
shasum -a 256 dist/OrbitDrop.app.zip > dist/OrbitDrop.app.zip.sha256
echo "Built: $task_root/$app_path"
