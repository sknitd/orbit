# Build and validation

## macOS prerequisites

Use macOS 14 or later with Xcode 16 or later and its macOS SDK selected, Swift 6, Python 3, Git, and CMake. Accept Xcode's license and finish its first-launch setup through the normal Xcode tooling. Command Line Tools alone do not replace the full Xcode application required for `xcodebuild` tests.

```bash
xcodebuild -version
swift --version
cmake --version
python3 --version
bash Scripts/build.sh
```

The build script performs these steps:

1. Fetch libwebp at the pinned commit, configure/build `arm64` and `x86_64` separately to keep CPU-specific SIMD flags isolated, and combine their static libraries with `lipo`.
2. Create all required icon sizes and `AppIcon.icns` from `Resources/AppIcon.png`.
3. Regenerate `OrbitDrop.xcodeproj` and its shared scheme from the current sources.
4. Run portable `OrbitCore` tests with `swift test --parallel`.
5. Run Debug native engine tests with `xcodebuild test`.
6. Build Release with `ONLY_ACTIVE_ARCH=NO`, bundle dependency notices, apply an ad hoc signature, and verify the signature.
7. Package the application and write a SHA-256 checksum.

Successful output locations are:

```text
build/DerivedData/Build/Products/Release/OrbitDrop.app
dist/OrbitDrop.app.zip
dist/OrbitDrop.app.zip.sha256
```

The final console line is `Built: <checkout>/build/DerivedData/Build/Products/Release/OrbitDrop.app`. Confirm the executable architectures and open the application on the Mac:

```bash
lipo -archs build/DerivedData/Build/Products/Release/OrbitDrop.app/Contents/MacOS/OrbitDrop
shasum -a 256 -c dist/OrbitDrop.app.zip.sha256
open build/DerivedData/Build/Products/Release/OrbitDrop.app
```

Release targets are universal Apple Silicon/Intel. `ORBIT_ARCHS` changes the libwebp build only; narrowing it without also changing the Xcode architecture settings can cause link failures. The default is the supported universal configuration.

`Vendor/`, `build/`, and `dist/` are generated local paths. The WebP script refuses to replace an existing vendor checkout with local changes. Source URLs and commit pins are in `Scripts/prepare-webp.sh`. Xcode project generation is deterministic; run it again after adding source or native test files.

The icon is an adaptation of the user-supplied Orbit logo. Its generated raster is the input to the macOS iconset conversion. Upstream libwebp `COPYING` and `PATENTS` notices are copied into `Contents/Resources/ThirdParty` when packaging.

## Linux development environment

On a Linux host with Swift 6, the portable package can be validated with:

```bash
swift test --parallel
```

`Package.swift` intentionally includes only `OrbitCore`. These tests cover capability filtering, radial geometry, actual-drop payload matching, and ZIP metadata safety. They do not compile the application or native engines. Linux has no AppKit/PDFKit/AVFoundation macOS SDK and cannot validate Finder, Input Monitoring, Spaces, or the finished `.app`.

Do not describe a directory assembled on Linux as a compiled macOS application. `Scripts/build.sh` explicitly fails on a non-Darwin host. A macOS CI result or a Mac build is required for native compilation and linking; a real Mac session is required for interactive acceptance.

## GitHub Actions and Git-only retrieval

`.github/workflows/macos.yml` runs on `macos-15` for pushes to `main` or `codex/orbitdrop`, and supports manual dispatch. It uploads the application, build log, checksum, and XCTest result bundles as Actions artifacts. It also publishes a separate, workflow-owned orphan branch named `codex/builds/run-<run-id>-<attempt>` containing:

- `build-status.json`, including the source commit and build-step outcome;
- `build.log` when available;
- `OrbitDrop.app.zip` and `OrbitDrop.app.zip.sha256` only when packaging produced them.

The workflow requires repository `contents: write` permission for these result branches. These branches contain build results, not development source. A failed run can publish its logs without an application. A successful CI build does not satisfy interactive Finder acceptance.

Git access is enough to retrieve the result; GitHub API authentication is not assumed. First list available result branches:

```bash
git ls-remote --heads origin 'refs/heads/codex/builds/*'
```

Replace the run and attempt placeholders below with a returned branch, fetch it without checking it out, then inspect the status and log:

```bash
git fetch origin 'refs/heads/codex/builds/run-<run-id>-<attempt>:refs/remotes/origin/codex/builds/run-<run-id>-<attempt>'
task_report_ref='origin/codex/builds/run-<run-id>-<attempt>'
git show "${task_report_ref}:build-status.json"
git show "${task_report_ref}:build.log"
```

Check that `source_commit` is the intended source revision and that the outcome is successful before extracting its application:

```bash
mkdir -p retrieved/dist
git show "${task_report_ref}:OrbitDrop.app.zip" > retrieved/dist/OrbitDrop.app.zip
git show "${task_report_ref}:OrbitDrop.app.zip.sha256" > retrieved/dist/OrbitDrop.app.zip.sha256
cd retrieved
shasum -a 256 -c dist/OrbitDrop.app.zip.sha256
ditto -x -k dist/OrbitDrop.app.zip .
open OrbitDrop.app
```

The checksum file records the relative `dist/` path, so verification runs from `retrieved`. Use the Actions artifact download for `.xcresult` bundles; those bundles are not committed to the Git result branch.

## Signing and release acceptance

The build's ad hoc signature is suitable for development verification; it is not Developer ID signing or notarization. A distributed application may require macOS's normal user confirmation. Keep signature and TLS verification enabled. Production distribution needs a separate signing/notarization workflow and the interactive checks in [MANUAL-ACCEPTANCE.md](MANUAL-ACCEPTANCE.md).
