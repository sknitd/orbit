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

**32 macOS integration tests await execution on the macOS CI runner.** They create real image/PDF/audio/video/archive fixtures and verify output decoding, metadata removal, batching, collision protection, concurrent publication, source preservation, and cleanup after failures. Their results are not counted among the 37 tests above. The CI build is pending completion.

Finder drag gestures, Escape cancellation, Spaces, physical multiple-display behavior, accessibility, idle resource usage, and launch of the final Release app still require native runtime verification. No UI or performance acceptance result is claimed here.
