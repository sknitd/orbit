#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if ! command -v swift >/dev/null; then
  task_toolchain=/workspace/toolchains/swift-6.2-RELEASE-ubuntu24.04/usr/bin
  [[ -x "$task_toolchain/swift" ]] || { echo 'Install the official Swift 6 toolchain; see BUILD.md.' >&2; exit 1; }
  export PATH="$task_toolchain:$PATH"
fi
task_cache="$task_root/build/cloud-cache"
mkdir -p "$task_cache/clang" "$task_cache/swiftpm" "$task_cache/config" "$task_cache/security"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_cache/clang"
export CLANG_MODULE_CACHE_PATH="$task_cache/clang"
swift test --jobs 4 --cache-path "$task_cache/swiftpm" \
  --config-path "$task_cache/config" --security-path "$task_cache/security"
