# NotchOrbitPlus 0.3 evaluation

NotchOrbitPlus is separate from NotchOrbit and OrbitDrop. Its **31 dashboard entries** include the nineteen explicitly named OmniNotch reference areas, inherited File Actions, Quick Launcher, Workflows and nine new tools. The public reference was inspected on October 4, 2026; no proprietary code or OmniNotch branded assets were copied. [implemented-features.md](implemented-features.md) describes source behavior and [known-limitations.md](known-limitations.md) records practical limits.

## Evidence status

**The source-matched macOS build and independent package audit passed.** The completed run executed 37 shared core, 129 NotchOrbitPlus core and 123 hosted native tests: **289 passed, zero failures and zero skipped tests**. The 129 core tests also passed on cloud Linux with Swift 6.2. Native execution, universal compilation, signing, startup, previews and idle measurements below come from the genuine Mac runner. This release is ad hoc signed, **not notarized**.

Source: `7dc43a6aec2a4d14657d41186c193b850dcfa43e` · [CI run 37220531371](https://github.com/sknitd/orbit/actions/runs/37220531371) · [artifact commit 497ffa0672eadf61168e0974c99416086b0b2121](https://github.com/sknitd/orbit/tree/497ffa0672eadf61168e0974c99416086b0b2121)

| Check | Executed evidence |
| --- | --- |
| NotchOrbitPlus portable core | **129 passed on Linux and macOS**; no account/hardware inference |
| Shared portable core | **37 passed on the source-matched Mac run**; also passed on Linux |
| Hosted native tests | **123 passed**, zero failures/skips; all discovered cases have individual passed entries |
| Total tests | **289 passed**: 37 shared + 129 Plus core + 123 native |
| Build SDK | Xcode **26.6**, macOS SDK **26.5**, Apple Swift **6.3.3**, arm64 host; public FoundationModels API typechecked |
| Release package | **0.3.0**, `com.sknitd.NotchOrbitPlus`, **arm64 + x86_64** verified in CI and independently in the ZIP |
| Minimum OS | **14.0** verified in Info.plist and both Mach-O deployment commands; minimum-OS runtime remains acceptance |
| FoundationModels | **Weak-linked in both slices**; newer on-device AI stays availability-gated |
| Signing/startup | **Strict ad hoc signature verification and three-second startup passed**; no Apple credential bindings, notarization pending credentials |
| Native renders | **54 actual native PNGs**, including all **31 dashboard views**, feature/settings fixtures, onboarding, updates and semicircle |
| Public services | **Three HTTP 200 responses**: Open-Meteo city/forecast and Frankfurter; production Swift decoding passed; FX date **2026-10-02** |
| Published updates | Public stable feed and package **HTTP 200 without authentication**; source, version, bytes and SHA-256 match CI exactly |
| Idle CPU | **0.090% mean CPU**, below the **3%** budget; eleven actual samples |
| Idle RSS | **87.245 MB sampled peak RSS**, below the **250 MB** budget |

The [0.3 ZIP](https://github.com/sknitd/orbit/raw/497ffa0672eadf61168e0974c99416086b0b2121/NotchOrbitPlus.app.zip) contains **8,414,997 bytes** and SHA-256 **`f258c6fa17c303a088759cd87e6aa12035e451151aabb6cc7afef30c8f3b89fa`**. Independent inspection verified ZIP integrity, executable permissions, bundle identity/resources, both architectures, deployment commands, weak FoundationModels links and packaged metadata for all five AppIntents. Darwin signing and launch passed on the Mac runner; Linux inspection does not execute the app.

The Git-only result branch publishes `build-status.json`, `build.log`, `sdk-inventory.json`, `package-verification.json`, `launch-smoke.log`, `idle-performance.json`, test logs, `public-probes/`, native PNGs and the successful app archive/checksum. The artifact status matches the exact source commit and successful run above. Independent anonymous checks also verified the immutable download and stable-feed archive bytes/checksum.

The independent [package audit](docs/0.3.0-package-audit.json), [immutable download audit](docs/0.3.0-download-audit.json), [public update audit](docs/0.3.0-public-update-audit.json) and [raw idle measurement](docs/0.3.0-idle-performance.json) retain the inspected source, checksum and measured values.

## Test suites and fixture scope

The following describes the executed portable and hosted native suites. All native cases passed, including four actual hosting/window visibility regressions and three multi-store sync failure/recovery fixtures. Fixture data is identified by test/output names and documentation captions; it does not establish real devices, accounts, permission prompts or physical Finder events.

| Area | Checks and practical limits |
| --- | --- |
| All 31 dashboard modules | Production module factory, minimum-width native renders, visibility/order migration and safe display frames; rendering leaves explicit Connect/Enable/Start actions untouched |
| Now Playing / System source | Injected MediaRemote symbol/response/control checks, metadata/artwork projection, unavailable controls and stale-position handling; no live user player or browser discovery is established |
| Lyrics and artwork | Bounded LRCLIB/Spotify-artwork client transport cases, unsafe/redirect/error/cancellation handling and timestamped lyric parsing; no live account or LRCLIB match is implied |
| Volume & Brightness | Lifecycle fixtures cover explicit interception policy, modified/unsupported key pass-through, paired key events, permission/presentation availability and labeled HUD states; real keyboard/display hardware remains acceptance |
| Screenshot Shelf | Geometry, file validation, managed-copy publication, cancellation and source-preservation checks; actual ScreenCaptureKit selection, permission prompts and physical screen recording remain acceptance |
| Video workflows | Real generated video files exercise the inherited media engine, H.264 output validation, smaller-output requirements, ZIP and failure rollback; fixture video processing is separate from live recording |
| Image workflows and explicit run APIs | Real resize/conversion/compression/batch-ZIP files, collision handling, cancellation, symlinks and concurrent source replacement; explicit asynchronous runs return durable files outside temporary input storage and propagate failure without a success callback |
| Color Picker | Validated sRGB formatting/palettes, local-history preservation, invalid persisted bytes, save failure and actual native view rendering; NSColorSampler interaction remains acceptance |
| Devices, Status and Network | Public-data normalization, unknown battery/activity/Focus states, traffic counter reset/interface change and tunnel indicators; fixtures do not assert attached AirPods, a particular recording app, a Focus mode or a live VPN provider |
| Currency and World Clock | Dated rate conversion, missing rates and dated rate labels, saved-zone persistence, DST/meeting conversion and labeled native fixtures; account-free HTTP probes are recorded separately |
| GitHub Actions | Read-only production client pagination, fixed-origin/redirect/HTTP/rate-limit/error cases with transport fixtures; no authenticated repository/account access is claimed |
| Focus Stats | Completed-session history, pauses/cancellation, sleep/deadline recovery, legacy-count migration, corrupt-history preservation and labeled completed-history chart; no historical dates are invented |
| Appearance, priorities and display settings | Isolated persistence, native dark-theme/priority/display-Spaces previews, actual custom priority selection and corrupt/wrong-type original retention; preview rendering does not enable sound or permissions |
| Version-2 sync | Version-1 migration; two device identities; task tombstones; clock skew; independent library categories; concurrent whole-category variants; logical target allowlists; coordinated publication/reread; oversized/corrupt/symlink/identity mismatch preservation; local-folder resolution and no app launch during bundle lookup; failed multi-store apply restores exact original files, defaults and store memory, with a private recovery directory and blocked sync if restoration fails |
| Retained native visibility | Actual SwiftUI/NSWindow hide, reopen, observed-state publication and teardown fixtures verify deferred/coalesced callbacks and cancellation without stale resumption or graph reentrancy; no permission is requested |
| AppIntents and keyboard | Bounded/scoped file coordinator and durable workflow output fixtures; intent metadata and source navigation policies; actual installed Shortcuts discovery, physical keyboard/VoiceOver and user prompts remain acceptance |
| Existing integrations | EventKit projection/Join safety, real Quick Look selected-file ownership, native pasteboard opt-in/confidential markers, local Vision OCR/cancellation, and update-client/archive/installer-rejection cases |

Screenshot, chart, media and compact images use actual native view code. Synthetic rates, recorded sessions, metadata and status fixtures are identified by output names and documentation captions. A native render or launch smoke does not establish permission acceptance, real account data or physical-notch interaction.

## Preview paths

These links match the **54 source-matched native captures** from the completed run. The docs copies preserve their original bytes; visual review checks legibility and clipping without editing the images.

- [Screenshot Shelf](docs/NotchOrbitPlus-Dashboard-capture.png), [Color Picker](docs/NotchOrbitPlus-ColorPicker.png), [GitHub Actions](docs/NotchOrbitPlus-Dashboard-githubActions.png).
- [Dated currency fixture](docs/NotchOrbitPlus-Currency-fixture-dated-rates.png), [saved-zone fixture](docs/NotchOrbitPlus-WorldClock-fixture-saved-zones.png), [completed focus-history fixture](docs/NotchOrbitPlus-FocusStats-fixture-completed-history.png).
- [Unconnected media fixture](docs/NotchOrbitPlus-Media-fixture-unconnected.png), [unavailable-control media fixture](docs/NotchOrbitPlus-Media-fixture-restricted-controls.png), [compact HUD fixture](docs/NotchOrbitPlus-Compact-fixture-hud.png).
- [Dark appearance fixture](docs/NotchOrbitPlus-Appearance-fixture-dark.png), [custom priority fixture](docs/NotchOrbitPlus-Priority-fixture-custom.png), [custom compact-priority fixture](docs/NotchOrbitPlus-Compact-fixture-custom-priority.png), [display/Spaces settings fixture](docs/NotchOrbitPlus-DashboardSettings-fixture-display-spaces.png).

## Idle measurement scope

The Release smoke harness checks survival for three seconds, warms up for eight seconds, then records eleven samples spanning ten one-second intervals. It calculates mean application CPU from cumulative CPU-time deltas over measured wall time; 100% represents one occupied CPU core. RSS is converted from KiB to decimal MB. Budgets are **3% mean CPU** and **250 MB sampled peak RSS**; a measurement/budget failure fails the smoke check.

The measured result is **0.090% CPU / 87.245 MB peak RSS**. Raw intervals, budget outcomes, source identity and measurement conditions belong in [idle-performance.json](https://github.com/sknitd/orbit/blob/497ffa0672eadf61168e0974c99416086b0b2121/idle-performance.json). This measures the owned app process with default local setup, without enabling tools, accounts, playback, permissions or network actions. It excludes WindowServer, GPU allocations and other processes. It does not establish every Mac model, long uptime, battery impact or 60/120 Hz interactive responsiveness.

## Sync and distribution

Sync is disabled until a shared folder is selected and enabled. Version 2 adds logical launcher pins, workflow presets, saved palettes, appearance, live priorities and World Clock zones to notes/tasks/dashboard settings. Absolute file paths, security bookmarks, credentials, clipboard, shelf files, pick history, meeting data and display geometry remain local. Folder pins require an explicit local choice on each Mac; applications resolve by bundle ID and Shortcuts need a matching installed identifier.

Version-1 snapshots are imported safely; all syncing Macs must use **0.3.0** for version-2 snapshots, which 0.2.0 rejects. Task tombstones prevent stale resurrection. Concurrent changes in one library category retain whole variants for explicit resolution, with a private backup; different categories merge independently. Corrupt stored bytes and wrong property types block automatic replacement. Folder JSON is readable to whoever has folder access. Local coordinated-file fixtures do not prove provider upload, delivery or two physical Macs.

All update automation starts off. Ad hoc builds can check/download verified updates for manual installation. Automatic replacement requires a trusted Developer ID signed running app and a same-team notarized update. The signing/notarization pipeline is implemented; **ad hoc signing is not notarization**. The completed CI records no Apple signing/notary credential bindings, verified ad hoc signing and notarization status `pending_credentials`. Developer ID, notarization, stapling, trusted installation and recovery require appropriate Apple credentials and an actual signed release; those outcomes are not inferred from test fixtures.

Cloud regression checks also passed the unchanged NotchOrbit suite (**27 tests**) and OrbitDrop shared suite (**37 tests**). The 27 NotchOrbit checks are additional Linux regression evidence, outside the 289-test Plus Mac total.

## Earlier verified baseline

Version 0.2.0 source `c7ed6f4a36342ea1ec6fb7a57eefab0c67aef7ce` passed [run 37209047295](https://github.com/sknitd/orbit/actions/runs/37209047295): 37 shared core, 84 NotchOrbitPlus core and 59 hosted native tests, **180 total**, with no failures/skips. Universal Release compilation, strict ad hoc signature verification and startup passed; thirty native previews and three real HTTP 200 weather/FX decodes were recorded. The [immutable 0.2 artifact](https://github.com/sknitd/orbit/tree/33b34fdbbdb8770046b69861aa1f0ea375338aec) preserves that evidence. These historical results do not establish the new 0.3 source or package.

## Remaining Mac and account acceptance

- System Now Playing uses private MediaRemote, which Apple can change or restrict, including on macOS 15.4+. Missing access/symbols remain unavailable; Music/Spotify Automation is available. Real browser/player discovery, playback controls, artwork and position need acceptance. LRCLIB requires opt-in plus an explicit click, sends track metadata and can return no match; local LRC import remains available.
- Actual Screen Recording consent, area/window/display selection, Retina/multiple displays, silent recording and saved capture require an installed Mac. Recording is intentionally bounded to 1–60 seconds; protected-content/audio capture is not claimed. Real volume/mute/brightness keys, active outputs/displays and permission revocation also need hardware checks.
- Devices depends on exposed IOKit/HID/Bluetooth data. Unknown AirPods/peripheral batteries stay unavailable. CoreAudio input activity and public camera activity do not identify a specific recording app. Authorized Apple Focus exposes only its optional shared boolean, without identifying a Focus mode.
- Weather/FX are account-free public probes. Alpha Vantage stocks, seven merchant adapters and GitHub repository access require the user's valid credentials/scopes/plan. Sales labels UTC creation-day gross paid amounts, available order-attached refunds, coverage limits and dated USD conversion; it does not claim net revenue or refunds processed today. API response fixtures do not establish account totals.
- AI Usage performs an explicit documented Codex quota read through a user-selected signed-in CLI. Other providers use normalized imported reports. Synthetic subprocess tests establish protocol/cancellation behavior, without an authenticated subscription read or token extraction. Eligible-hardware FoundationModels inference also remains acceptance.
- Physical-notch/notchless and secondary-display geometry, Finder dragging, hover/click/delay, keyboard focus, actual Shortcuts discovery/execution, camera/Calendar/Reminders/Automation/Focus/Bluetooth permissions, AirDrop/Quick Look, two-Mac sync/provider conflicts, login registration, signed updates/recovery, sleep/Spaces/fullscreen, VoiceOver and Reduce Motion remain interactive acceptance. Intel and macOS 14 runtime acceptance are separate from universal compilation and minimum-OS metadata.

Each Mac needs its own permission grants and integration setup. Native rendering, temporary-file tests, public HTTP probes and idle startup measurements establish only their recorded scope.
