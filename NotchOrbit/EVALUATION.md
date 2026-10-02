# NotchOrbit evaluation

This evaluates the new NotchOrbit target separately from OrbitDrop. NotchOrbit uses the shared real file engines, while its activation tracker, screen layout, semicircular panel, application shell, bundle identity, and tests live under `NotchOrbit/`.

| Requirement | Current evidence | Status |
| --- | --- | --- |
| No modifier needed for activation | Monitor observes mouse-down/drag/up and Escape; activation API takes no modifier state | Reviewed; native Finder gesture pending |
| Fresh local file drag | Portable tests cover stale board counts, non-file payloads, duplicate/changed URLs, second writers and generation invalidation | Passed on Linux; native pasteboard cases pending |
| Lower semicircle selection | Portable 4/6/8/10-wedge centers, radial boundaries, angular gaps, inactive center/upper half and option-count tests | Passed on Linux |
| Safe notch/menu positioning | Portable layout tests verify panel and option positions outside the hardware-notch rectangle/menu area, including notchless fallback and small screens | Passed on Linux; physical Mac pending |
| Multiple screens | Portable negative origins, vertically stacked displays, pointer-based screen selection and screen removal/change cases | Passed on Linux after same-ID layout-change correction |
| Actual drop authorizes execution | Destination uses `NSDraggingInfo` pasteboard, existing-file payload validation and final wedge hit testing; hover/click/presentation callbacks only change selection | Code reviewed; live drag/drop pending |
| Cancellation | Portable leave/reentry, Escape/full cancel, changed board and mouse-up tests; app rechecks generation after asynchronous inspection | Passed on Linux; native event routing pending |
| Permission denied | Launch does not request access; tap failure reports a status and preserves Choose Files/manual destination path | Code reviewed; permission UI and relaunch pending |
| Real JPEG to WebP | Native test checks RIFF/WEBP bytes, actual decode, dimensions and unchanged source bytes | Written; native CI pending |
| Real five-image resize | Native test checks five unique outputs at 1600×800, actual decoding and unchanged source bytes | Written; native CI pending |
| Failure cleanup | Native invalid-second-image test checks exact remaining entry names/count and both source contents | Written; native CI pending |
| Native pasteboard contracts | Native tests use real isolated pasteboards for file URLs, rewriting to text, duplicates/non-file URLs and stopped monitor | Written; native CI pending |
| Native panel rendering | Hosted native test presents the actual panel, selects its real Convert category, checks frame/PNG dimensions and proves no transformation callback occurred | Written; native CI and visual review pending |
| Launch, signature and universal app | Build scripts require real Xcode/macOS, both architectures, signature validation and a short startup check | Native CI pending |
| Responsiveness and idle resource use | No idle polling loop is present in the input observer; media work uses shared asynchronous engines | Code reviewed; measurements pending |

The final portable run compiled and executed **27 tests with zero failures** on Swift 6.2 Linux: 11 activation, 4 payload, 6 semicircle geometry, and 6 screen-layout tests. The first run exposed stale activation when a screen retained its ID but its layout changed. The tracker now requires the full live zone/layout to match, and the original failing assertions passed unchanged in the rerun. The complete final output is saved outside the checkout at `/workspace/validation/NotchOrbit-core-tests.log`.

The complete native app/test dependency source graph also passed Swift 6 syntax parsing with `-target arm64-apple-macos14.0` (22 Swift files), activating its macOS conditional code. This is a preliminary grammar check; actual Apple framework type checking, linking and seven hosted native tests still require macOS CI.

Repeat portable tests from the NotchOrbit directory:

```bash
source /workspace/toolchains/activate-swift.sh
swift test --jobs 4 --scratch-path build/portable \
  --cache-path /workspace/toolchains/cache/swiftpm \
  --config-path /workspace/toolchains/cache/config \
  --security-path /workspace/toolchains/cache/security
```

Native CI must run the hosted `NotchOrbitTests` target. The panel test always writes `NotchOrbit-Convert.png` into `NotchOrbit/build/evaluation`, derived from its compiled source path, or into the absolute directory supplied by `NOTCHORBIT_EVAL_DIR`. It uses the actual native view's public bitmap rendering API, without a screen-recording permission or a fabricated image. A passing bitmap test still needs visual inspection of the saved panel.

Interactive acceptance remains pending: drag a JPEG from Finder without keys into the notch/top-center target; traverse a category and its option band; release over WebP; decode/reveal the output; verify the original; cancel through Escape, center/gap/outside release and leaving the activation corridor; repeat on a physical notched Mac and a secondary display. Repeat with Input Monitoring denied and then granted. Check Spaces, fullscreen apps, Retina rendering, Reduce Motion, VoiceOver and measured idle CPU/memory. Automated layout and engine tests do not establish these live results.
