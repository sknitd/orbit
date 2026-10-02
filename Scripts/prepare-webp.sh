#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
command -v cmake >/dev/null || { echo 'CMake is required to build the bundled WebP library.' >&2; exit 1; }
webp_commit=a4d7a715337ded4451fec90ff8ce79728e04126c
mkdir -p Vendor
if [[ ! -d Vendor/libwebp/.git ]]; then
  git clone --no-checkout https://github.com/webmproject/libwebp.git Vendor/libwebp
fi
if [[ -n "$(git -C Vendor/libwebp status --porcelain)" ]]; then
  echo 'Vendor/libwebp contains local changes; preserve them before refreshing the dependency.' >&2
  exit 1
fi
git -C Vendor/libwebp fetch origin "$webp_commit"
git -C Vendor/libwebp checkout --detach "$webp_commit"
[[ "$(git -C Vendor/libwebp rev-parse HEAD)" == "$webp_commit" ]]
webp_archs="${ORBIT_ARCHS:-arm64;x86_64}"
cmake -S Vendor/libwebp -B build/WebP-build \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX="$task_root/build/WebP" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$webp_archs" \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
cmake --build build/WebP-build --parallel 4
cmake --install build/WebP-build
mkdir -p Resources/ThirdParty
cp Vendor/libwebp/COPYING Resources/ThirdParty/libwebp-COPYING.txt
cp Vendor/libwebp/PATENTS Resources/ThirdParty/libwebp-PATENTS.txt
