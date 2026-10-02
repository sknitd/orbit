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

macOS CI run `36987150381`, attempt 1, tested commit `b4b0389`: **32 native integration tests executed; 24 passed and 8 failed**. The app and native test target compiled and linked successfully. The native test results are separate from the 37 portable tests above.

The native command used Xcode 16.4 and the macOS 15.5 SDK:

```bash
xcodebuild -project OrbitDrop.xcodeproj -scheme OrbitDrop \
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

| Native suite | Tests | Passed | Failed |
| --- | ---: | ---: | ---: |
| ImageEngineTests | 8 | 8 | 0 |
| PDFEngineTests | 5 | 5 | 0 |
| MediaEngineTests | 5 | 4 | 1 |
| FileEngineTests | 5 | 3 | 2 |
| ArchiveEngineTests | 5 | 2 | 3 |
| OutputNamingTests | 4 | 2 | 2 |

All eight failures compared different URL spellings for the same temporary files: expected `/var/...`, enumerated `/private/var/...`. The corrected assertions compare exact directory entry names and counts within the fixture directory. Existing cleanup, source-byte, collision, concurrency, and symlink assertions remain enabled and were strengthened where appropriate.

The earlier single-file ZIP basename defect is fixed and passed its native round-trip test in this run. The archive implementation archives a private source snapshot with the original basename. The folder round-trip test also passed.

The native tests use real generated image/PDF/audio/video/archive fixtures and verify actual decoded results. Successful cases include JPEG-to-PNG, WebP, five-image resizing, metadata/GPS removal, PDF merge/split/rendering, H.264 transcode, audio extraction and conversion, SHA-256, JSON formatting, and concurrent output naming. A new symbolic-parent alias archive regression test brings the enabled suite to 33 tests. The corrected assertions, additional test, and Release launch smoke await a fresh macOS CI run; no passing result is claimed for them yet.

Finder drag gestures, Escape cancellation, Spaces, physical multiple-display behavior, accessibility, idle resource usage, and launch of the final Release app still require native runtime verification. No UI or performance acceptance result is claimed here.
