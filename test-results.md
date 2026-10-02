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

macOS CI run `36987892464`, attempt 1, tested commit `f2c9247`: **33 native integration tests executed; 32 passed and 1 failed**. The app and native test target compiled and linked successfully. The native test results are separate from the 37 portable tests above.

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
| MediaEngineTests | 5 | 5 | 0 |
| FileEngineTests | 5 | 5 | 0 |
| ArchiveEngineTests | 6 | 5 | 1 |
| OutputNamingTests | 4 | 4 | 0 |

All rollback directory assertions now pass, using exact entry names and counts within the fixture directory rather than `/var` versus `/private/var` URL spellings. Source-byte, collision, concurrency, and symlink checks remain enabled.

The single failing test revealed a real archive traversal defect for a folder reached through a symlink in its parent path. Canonical child URLs did not match the lexical root prefix. The corrected traversal rejects a direct root symlink, then enumerates the resolved root; descendant links and special files remain rejected. The fix awaits the next macOS CI run.

The native tests use real generated image/PDF/audio/video/archive fixtures and verify actual decoded results. Successful cases include JPEG-to-PNG, WebP, five-image resizing, metadata/GPS removal, PDF merge/split/rendering, H.264 transcode, audio extraction and conversion, ZIP file/folder round trips, SHA-256, JSON formatting, and concurrent output naming. All 33 tests remain enabled. Release packaging and its startup smoke check have not run because the native test failure stops the build script.

Finder drag gestures, Escape cancellation, Spaces, physical multiple-display behavior, accessibility, idle resource usage, and launch of the final Release app still require native runtime verification. No UI or performance acceptance result is claimed here.
