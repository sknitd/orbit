# NotchOrbit evaluation

This evaluates the new NotchOrbit target separately from OrbitDrop. NotchOrbit uses the shared real file engines, while its activation tracker, screen layout, semicircular panel, application shell, bundle identity, and tests live under `NotchOrbit/`.

| Requirement | Current evidence | Status |
| --- | --- | --- |
| No modifier needed for activation | Monitor observes mouse-down/drag/up and Escape; activation API takes no modifier state | Reviewed; native Finder gesture pending |
| Fresh local file drag | Portable tests cover stale board counts, non-file payloads, duplicate/changed URLs, second writers and generation invalidation | Passed on Linux; corrected native ownership-boundary fixture awaiting rerun |
| Lower semicircle selection | Portable 4/6/8/10-wedge centers, radial boundaries, angular gaps, inactive center/upper half and option-count tests | Passed on Linux |
| Safe notch/menu positioning | Portable layout tests verify panel and option positions outside the hardware-notch rectangle/menu area, including notchless fallback and small screens | Passed on Linux; physical Mac pending |
| Multiple screens | Portable negative origins, vertically stacked displays, pointer-based screen selection and screen removal/change cases | Passed on Linux after same-ID layout-change correction |
| Actual drop authorizes execution | Destination uses `NSDraggingInfo` pasteboard, existing-file payload validation and final wedge hit testing; hover/click/presentation callbacks only change selection | Code reviewed; live drag/drop pending |
| Cancellation | Portable leave/reentry, Escape/full cancel, changed board and mouse-up tests; app rechecks generation after asynchronous inspection | Passed on Linux; native event routing pending |
| Permission denied | Launch does not request access; tap failure reports a status and preserves Choose Files/manual destination path | Code reviewed; permission UI and relaunch pending |
| Real JPEG to WebP | Native test checks RIFF/WEBP bytes, actual decode, dimensions and unchanged source bytes | Passed on macOS CI |
| Real five-image resize | Native test checks five unique outputs at 1600×800, actual decoding and unchanged source bytes | Passed on macOS CI |
| Failure cleanup | Native invalid-second-image test checks exact remaining entry names/count and both source contents | Passed on macOS CI |
| Native pasteboard contracts | Native tests use real isolated pasteboards for file URLs, rewriting to text, duplicates/non-file URLs and stopped monitor | First CI: two passed, one fixture assertion failed; strengthened fixtures awaiting rerun |
| Native panel rendering | Hosted native test presents the actual panel, selects its real Convert category, checks frame/PNG dimensions and proves no transformation callback occurred | Passed on macOS CI; saved 620×310 panel visually reviewed as legible without overlap |
| Launch, signature and universal app | Build scripts require real Xcode/macOS, both architectures, signature validation and a short startup check | Debug app compiled on macOS; Release packaging pending native-test rerun |
| Responsiveness and idle resource use | No idle polling loop is present in the input observer; media work uses shared asynchronous engines | Code reviewed; measurements pending |

The final portable run compiled and executed **27 tests with zero failures** on Swift 6.2 Linux: 11 activation, 4 payload, 6 semicircle geometry, and 6 screen-layout tests. The first run exposed stale activation when a screen retained its ID but its layout changed. The tracker now requires the full live zone/layout to match, and the original failing assertions passed unchanged in the rerun. The complete final output is saved outside the checkout at `/workspace/validation/NotchOrbit-core-tests.log`.

The complete native app/test dependency source graph also passed Swift 6 syntax parsing with `-target arm64-apple-macos14.0` (22 Swift files), activating its macOS conditional code. The corrected pasteboard fixtures passed the same syntax check.

The first real macOS CI run, `37036163152`, built source `101c7ea` and executed **seven hosted native tests: six passed and one failed**. All three real image tests and the panel-render test passed. The failure incorrectly expected `writeObjects` to increment `NSPasteboard.changeCount` after the test had already called `clearContents`. The test now measures the ownership change before clearing, validates the actual file representation, and exercises both fresh and stale activation baselines with the real board counts. Its text rewrite must expose the exact text and no file-URL representation. The duplicate fixture now requires AppKit to read two accessible, existing file entries before the monitor rejects them, avoiding rejection caused by nonexistent-file sandbox extensions. These corrections await a new macOS run; production freshness logic is unchanged.

Repeat portable tests from the NotchOrbit directory:

```bash
source /workspace/toolchains/activate-swift.sh
swift test --jobs 4 --scratch-path build/portable \
  --cache-path /workspace/toolchains/cache/swiftpm \
  --config-path /workspace/toolchains/cache/config \
  --security-path /workspace/toolchains/cache/security
```

Native CI runs the hosted `NotchOrbitTests` target. The panel test always writes `NotchOrbit-Convert.png` into `NotchOrbit/build/evaluation`, derived from its compiled source path, or into the absolute directory supplied by `NOTCHORBIT_EVAL_DIR`. It uses the actual native view's public bitmap rendering API, without a screen-recording permission or a fabricated image. The saved first-run panel was visually reviewed; this demonstrates native view rendering, while live Finder acceptance remains pending.

Interactive acceptance remains pending: drag a JPEG from Finder without keys into the notch/top-center target; traverse a category and its option band; release over WebP; decode/reveal the output; verify the original; cancel through Escape, center/gap/outside release and leaving the activation corridor; repeat on a physical notched Mac and a secondary display. Repeat with Input Monitoring denied and then granted. Check Spaces, fullscreen apps, Retina rendering, Reduce Motion, VoiceOver and measured idle CPU/memory. Automated layout and engine tests do not establish these live results.
