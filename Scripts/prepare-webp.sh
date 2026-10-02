#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
command -v cmake >/dev/null || { echo 'CMake is required to build the bundled WebP library.' >&2; exit 1; }
webp_commit=a4d7a715337ded4451fec90ff8ce79728e04126c
mkdir -p Vendor
if [[ ! -d Vendor/libwebp/.git ]]; then
  git clone --branch v1.5.0 --single-branch https://github.com/webmproject/libwebp.git Vendor/libwebp
fi
if [[ -n "$(git -C Vendor/libwebp status --porcelain)" ]]; then
  echo 'Vendor/libwebp contains local changes; preserve them before refreshing the dependency.' >&2
  exit 1
fi
git -C Vendor/libwebp fetch origin "$webp_commit"
git -C Vendor/libwebp checkout --detach "$webp_commit"
[[ "$(git -C Vendor/libwebp rev-parse HEAD)" == "$webp_commit" ]]
webp_archs="${ORBIT_ARCHS:-arm64;x86_64}"
IFS=';' read -r -a architectures <<< "$webp_archs"
for architecture in "${architectures[@]}"; do
  [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { echo 'Unsupported architecture.' >&2; exit 1; }
  # Configure each CPU separately: SIMD detection in libwebp must not mix
  # x86 compiler flags with arm64 when building a universal binary.
  cmake -S Vendor/libwebp -B "build/WebP-$architecture-build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$task_root/build/WebP-$architecture-install" \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  cmake --build "build/WebP-$architecture-build" --parallel 4
  cmake --install "build/WebP-$architecture-build"
done
mkdir -p build/WebP/lib build/WebP/include
cp -R "build/WebP-${architectures[0]}-install/include/" build/WebP/include/
for library in libwebp.a libsharpyuv.a; do
  inputs=()
  for architecture in "${architectures[@]}"; do inputs+=("build/WebP-$architecture-install/lib/$library"); done
  lipo -create "${inputs[@]}" -output "build/WebP/lib/$library"
  lipo -info "build/WebP/lib/$library"
done
mkdir -p Resources/ThirdParty
cp Vendor/libwebp/COPYING Resources/ThirdParty/libwebp-COPYING.txt
cp Vendor/libwebp/PATENTS Resources/ThirdParty/libwebp-PATENTS.txt
