# NotchOrbit evaluation

The final macOS Release build succeeded for source commit `18bc8fac7c55bacd87e3e987fe0280530558925d` in [CI run 37037710220](https://github.com/sknitd/orbit/actions/runs/37037710220). All **71 tests passed**: 37 shared OrbitCore tests, 27 NotchCore tests, and 7 hosted native tests. Both Apple Silicon and Intel executable architectures, strict ad hoc signature verification, and a three-second startup check passed.

NotchOrbit uses the shared real file engines. Its activation tracker, screen layout, semicircular panel, application shell, bundle identity, project, and tests live under `NotchOrbit/`.

| Requirement | Evidence | Status |
| --- | --- | --- |
| No modifier needed for activation | Monitor observes mouse-down/drag/up and Escape; activation API takes no modifier state | Reviewed; live Finder gesture pending |
| Fresh local file drag | Portable tests cover stale ownership counts, non-file payloads, duplicate/changed URLs, second writers and generation invalidation; native tests verify real pasteboard contracts | Passed on Linux and macOS |
| Lower semicircle selection | Tests cover 4/6/8/10-wedge centers, radial boundaries, angular gaps, inactive center/upper half and option counts | Passed on Linux and macOS |
| Safe notch/menu positioning | Layout tests cover hardware-notch exclusion, menu area, notchless fallback and small screens; native panel test checks its actual display bounds | Passed; physical notched Mac pending |
| Multiple screens | Tests cover negative origins, stacked displays, pointer-based selection, screen removal and changed layout with the same screen ID | Passed; live display switching pending |
| Actual drop authorizes execution | Destination reads the current `NSDraggingInfo` pasteboard, validates existing file URLs and the final action hit; hover/click only selects | Reviewed; live drag/drop pending |
| Cancellation | Tests cover leaving/reentry, full cancel, changed pasteboard and mouse-up; app rechecks live payload and generation after asynchronous inspection | Passed; native event routing pending |
| Permission denied | Launch does not request access; tap failure reports status and preserves Choose Files/manual destination | Reviewed; macOS permission UI/relaunch pending |
| Real JPEG to WebP | Native test checks RIFF/WEBP bytes, actual decode, dimensions and unchanged source bytes | Passed on macOS |
| Real five-image resize | Native test checks five unique outputs at 1600×800, actual decode and unchanged source bytes | Passed on macOS |
| Failure cleanup | Native invalid-second-image test checks exact remaining entries and both original file contents | Passed on macOS |
| Native pasteboard contracts | Three tests use actual isolated pasteboards for fresh file URLs, ownership changes, rewriting to text, duplicate entries and stopped monitoring | All three passed on macOS |
| Native panel rendering | Hosted test presents the actual panel, selects Convert, checks bounds/PNG dimensions and verifies no action callback occurred | Passed; 620×310 preview visually reviewed |
| Universal Release app | Xcode 16.4/macOS 15.5 SDK builds `arm64` and `x86_64` with a macOS 14 minimum; `lipo` verifies both | Passed |
| Signature and startup | Strict ad hoc signature verification and Release process survival for three seconds | Passed; not notarized |
| Responsiveness and idle resource use | Input observer has no idle polling loop; media work uses shared asynchronous engines | Reviewed; measurements pending |

## Download provenance

The [packaged app](https://github.com/sknitd/orbit/raw/22d4fddbf7dda0beb49e88219c3087a5f6a63f83/NotchOrbit.app.zip), checksum, build log, startup log, status, and native preview are retained at immutable artifact commit `22d4fddbf7dda0beb49e88219c3087a5f6a63f83`. The status records the exact source commit and successful outcome. Documentation added after that source commit does not change the packaged executable.

The ZIP contains a real `NotchOrbit.app` bundle with identifier `com.sknitd.NotchOrbit`, version `0.1.0`, a universal Mach-O executable, the Orbit icon, and bundled WebP license/patent notices. It is 3,009,559 bytes; the downloaded archive's checksum was independently checked after retrieval:

```text
14c83678ab46a2254258726c858bd7a0b4f142c48976db461bb938e27ad9ebc8
```

## Portable and native evaluation

The portable NotchCore suite has **27 tests with zero failures**: 11 activation, 4 payload, 6 semicircle geometry, and 6 screen-layout tests. It passed on Swift 6.2 Linux and again on macOS. Run it from the repository root:

```bash
bash NotchOrbit/Scripts/cloud-core-tests.sh
```

The macOS build script runs these tests and the hosted `NotchOrbitTests` target before packaging:

```bash
bash NotchOrbit/Scripts/build.sh
```

The seven native tests comprise three real image operations, three pasteboard contracts, and one actual panel rendering evaluation. The panel test writes `NotchOrbit-Convert.png` to `NotchOrbit/build/evaluation`, or the absolute directory supplied by `NOTCHORBIT_EVAL_DIR`. It uses the actual native view's public bitmap rendering API. The [saved preview](docs/NotchOrbit-Convert.png) was visually reviewed for readable text, distinct action bands, and overlap. This establishes native view rendering; it does not establish physical notch placement or live Finder acceptance.

## Interactive acceptance still required

On a supported Mac, drag a JPEG from Finder without keys into the notch/top-center target. Traverse Convert into WebP, release over WebP, decode/reveal the output, and verify the original. Check cancellation by Escape, center/gap/outside release, and leaving the activation corridor. Repeat on a physical notched Mac and a secondary display, and with Input Monitoring denied and then granted.

Check Spaces, fullscreen apps, Retina rendering, Reduce Motion, VoiceOver, and measured idle CPU/memory. Automated layout, engine, rendering and startup tests do not establish these interactive results. The development build is ad hoc signed and is not Developer ID signed or notarized.
