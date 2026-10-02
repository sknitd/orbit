# Test results

Portable Swift 6.2 tests passed on Debian 13 x86_64: **37 tests, 0 failures**.

| Suite | Tests | Result |
| --- | ---: | --- |
| ActionResolverTests | 12 | Passed |
| ArchiveSecurityTests | 11 | Passed |
| DropPayloadValidatorTests | 5 | Passed |
| RadialGeometryTests | 9 | Passed |

The tests exercise supported action filtering, mixed selections, codec availability, wedge angles and boundaries, screen containment, real-drop payload matching, and ZIP path/link/size/header security. They run the actual OrbitCore library.

The tested command was:

```bash
cd /workspace/orbit
SWIFTPM_MODULECACHE_OVERRIDE=/workspace/toolchains/cache/clang \
CLANG_MODULE_CACHE_PATH=/workspace/toolchains/cache/clang \
/workspace/toolchains/swift-6.2-RELEASE-ubuntu24.04/usr/bin/swift test \
  --jobs 4 \
  --cache-path /workspace/toolchains/cache/swiftpm \
  --config-path /workspace/toolchains/cache/config \
  --security-path /workspace/toolchains/cache/security
```

The explicit cache paths keep generated files inside the writable workspace; the machine's home directory is read-only.

Swift 6 syntax parsing passed for **19 native app/test source files**. The exact expanded command and outcome are saved outside the checkout at `/workspace/validation/native-swift6-parse.log`. To repeat the same check:

```bash
cd /workspace/orbit
python3 - <<'PY'
from pathlib import Path
import subprocess
files = sorted(Path('Sources/OrbitDrop').rglob('*.swift'))
files += sorted(Path('Tests/OrbitDropTests').rglob('*.swift'))
subprocess.run([
    '/workspace/toolchains/swift-6.2-RELEASE-ubuntu24.04/usr/bin/swiftc',
    '-frontend', '-parse', '-swift-version', '6',
    *map(str, files)
], check=True)
PY
```

Syntax parsing does not resolve Apple framework imports, type-check native APIs, link an app, or execute native transformations.

macOS CI [run 36988372694](https://github.com/sknitd/orbit/actions/runs/36988372694), attempt 1, tested source **`63ba651111477c9c2403e05e1bfa185ad5a9b300`** with Xcode 16.4 (16F6) and the macOS 15.5 SDK. The portable command executed all 37 XCTest cases successfully on this runner. The native Debug suite executed **33 integration tests, 0 failures**.

```bash
xcodebuild -project OrbitDrop.xcodeproj -scheme OrbitDrop \
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

| Native suite | Tests | Result |
| --- | ---: | --- |
| ImageEngineTests | 8 | Passed |
| PDFEngineTests | 5 | Passed |
| MediaEngineTests | 5 | Passed |
| FileEngineTests | 5 | Passed |
| ArchiveEngineTests | 6 | Passed |
| OutputNamingTests | 4 | Passed |

These tests use real generated image/PDF/audio/video/archive fixtures and verify decoded results and preserved inputs. They cover JPEG-to-PNG, WebP and alpha, five-image resizing, metadata/GPS removal, PDF merge/split/rendering and rotation, H.264 transcode, audio extraction/conversion, ZIP file/folder round trips including a symbolic parent-path alias, unsafe archive rejection, SHA-256, JSON formatting, concurrent output naming, and failed-operation cleanup. All tests remain enabled.

The same run then successfully built the **Release universal `x86_64` / `arm64` application**, bundled the Orbit icon and libwebp notices, applied and verified its ad hoc signature, and passed the three-second executable launch smoke. The process remained running until the script terminated it; this check does not establish interactive UI acceptance.

The retrieved artifact was verified against its checksum, extracted, and inspected on Linux. Its actual executable is a universal Mach-O with both architectures; the bundle has macOS 14.0 minimum, `LSUIElement=true`, the correct executable/icon names, `.icns`, signature resources, and both dependency notices. The Git result branch is `codex/builds/run-36988372694-1`; its `build-status.json` records the exact successful source revision above.

```text
OrbitDrop.app.zip: 4,087,977 bytes
SHA-256: 9459845bcbd6216425eadd5d58b067901784c509f20550818d56251168eeeba6
```

The workspace contains `dist/OrbitDrop.app.zip`, its `.sha256` file, and the extracted `dist/OrbitDrop.app`. The full native build log and status are retained outside the source checkout at `/workspace/validation/macos-build.log` and `/workspace/validation/macos-build-status.json`. They can be retrieved again through Git using BUILD.md's instructions.

Finder drag gestures, Escape cancellation, Spaces, physical multiple-display behavior, accessibility, permission prompts, and idle resource usage still require the interactive checks in [MANUAL-ACCEPTANCE.md](MANUAL-ACCEPTANCE.md). Native compilation, engine tests, Release startup survival, and packaging passed; no complete UI or performance acceptance, Developer ID signature, or notarization is claimed.
