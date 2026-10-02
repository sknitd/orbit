#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS image tools are required to create AppIcon.icns.' >&2; exit 1; }
icon_source=Resources/AppIcon.png
[[ -f "$icon_source" ]] || icon_source=../Resources/AppIcon.png
[[ -f "$icon_source" ]] || { echo 'The NotchOrbit icon source is missing.' >&2; exit 1; }
mkdir -p build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$icon_source" --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" "$icon_source" --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
[[ -s build/AppIcon.icns ]]
