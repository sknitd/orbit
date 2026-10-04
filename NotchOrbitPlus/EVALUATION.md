# NotchOrbitPlus 0.3.0 build 4 evaluation

The expanded app has **45 dashboard tools**, including **14 new tools**. NotchOrbit and OrbitDrop retain their separate projects, bundles and storage. [Implemented behavior](implemented-features.md) and [known limits](known-limitations.md) describe the scope of each feature.

## Executed evidence

The source-matched [macOS run 37232350966](https://github.com/sknitd/orbit/actions/runs/37232350966) passed for source `b5e99d868cc4e34754cf827adbd0012c2e129a78`. All **395 tests passed**, with **zero failures and zero skipped native tests**: 37 shared core, 173 Plus core and 185 hosted native cases. The requested `bash NotchOrbitPlus/Scripts/cloud-core-tests.sh` separately passed all **173 tests** on Linux with official Swift 6.2. Linux parsing does not establish a native build.

The immutable [artifact commit 9f39669d503deacaf1adb19a963eb5f280611c96](https://github.com/sknitd/orbit/tree/9f39669d503deacaf1adb19a963eb5f280611c96) preserves the genuine Mac logs, SDK inventory, signature/startup/performance checks, public-service responses, provider documentation, native PNGs, ZIP and checksum.

| Check | Actual result |
| --- | --- |
| Shared / Plus portable core | **37 / 173 passed on macOS**; both also passed on Linux |
| Hosted native cases | **185 unique passed entries**, zero failures/skips; exact source inventory checked independently |
| Total | **395 passed**; unchanged NotchOrbit's **27 Linux regressions** are additional, outside this total |
| Native SDK | **Xcode 26.6**, macOS SDK **26.5**, Apple Swift **6.3.3**, arm64 runner |
| Public API probes | FoundationModels, Translation and on-device Speech typechecked; Translation/Speech checked for **arm64 + x86_64** |
| Release app | **0.3.0, build 4**, `com.sknitd.NotchOrbitPlus`, **arm64 + x86_64** |
| Minimum system | **14.0** in Info.plist and both Mach-O slices; minimum-system runtime remains acceptance |
| New frameworks | FoundationModels and Translation each have exactly one **weak load** in both slices |
| Bundled resources | Both Python CLI helpers and both plugin samples match the exact compiled source bytes |
| Signing/startup | Strict **ad hoc** verification and **three-second startup passed**; **not notarized** |
| Native previews | **109 PNGs**, including all **45 dashboard tools** and labeled primary/secondary compact fixtures |
| Production plugin probe | Exact production runner compiled on macOS; JSON execution, denied outside read/write and explicit chosen-folder read passed; these four checks are outside the 395 XCTest total |
| Compact accessibility probe | Exact production compact view and native fixture helper compiled on macOS; Copy/Reveal AXButton controls are reachable through the owned hosting/window tree and native view lookup. Press checks through both lookups each route the displayed fixture once without opening another tool; outside the 395 XCTest total |
| Public HTTP | **Five HTTP 200 validated responses**; production Swift decodes passed for city/forecast/AQI-UV-PM2.5/minutely rain/FX |
| Publication | Anonymous immutable download and stable-feed ZIP match source, size and SHA-256 |
| Idle performance | **0.715% mean CPU**, **89.358 MB sampled peak RSS**; budgets **3% / 250 MB** passed |

The [app ZIP](https://github.com/sknitd/orbit/raw/9f39669d503deacaf1adb19a963eb5f280611c96/NotchOrbitPlus.app.zip) contains **11,261,776 bytes**; SHA-256 **`da9461b610ee4e179835f0493b82bfb0517b18b2689fe83b625380cee1421f0c`**. Independent inspection checks ZIP integrity, paths/permissions, identity/resources, both architecture/deployment commands, weak links, embedded signature metadata and all five AppIntents metadata entries. Actual Darwin signature/launch checks come from CI. Independent audits: [package](docs/0.3.0-build4-package-audit.json), [tests/previews](docs/0.3.0-build4-test-audit.json), [compact accessibility](docs/0.3.0-build4-compact-accessibility-audit.json), [immutable download](docs/0.3.0-build4-download-audit.json), [public feed](docs/0.3.0-build4-public-update-audit.json), [raw idle samples](docs/0.3.0-build4-idle-performance.json).

## Expansion tests and fixture scope

| Feature | Executed scope and remaining boundary |
| --- | --- |
| Context Rules | Ordered/default-off matching, hidden targets and priority logic; disabled observer/one-shot preview native states. Real app/call/Calendar/music/Finder transitions and busy-editor/Undo interaction still need a Mac. Rules only select/show tools. |
| Ask Orbit files | Real bounded text/PDF/image reads, local OCR, editable injected proposals, CSV validation, exclusive output copies, cancellation/source-change refusal and unchanged-output Undo. Model inference on eligible Apple Intelligence hardware remains acceptance. Originals are not renamed. |
| Downloads / Commands | Actual private partial-file growth/rename fixtures; user-known totals/ETA; lifecycle; byte-verified installed helpers invoke a real command and deliver matching start/finish messages through an owned private socket. Browser download APIs and the whole Xcode build are not inferred. |
| Snippets / Habits | Real persistence, corrupt-byte preservation, confidential-local snippet exclusion, incoming merge/rollback, Gregorian streaks and 49-day heatmap fixtures. Two-Mac provider delivery remains acceptance. |
| Clipboard / Search | Local transform/parser/ranking/bounds/visibility cases, private markers and provider-injected native behavior. No Spotlight or account-cache indexing; physical keyboard result activation remains acceptance. |
| Translate / Dictation | Unstarted/canceled local Translation view lifecycle; injected on-device session events, measured waveform levels, permission ordering, hide/hold/final/save-failure handling and once-only Quick Note append. Actual model preparation/languages/microphone/hold keys need hardware. |
| QR / 2FA Codes | Real Core Image PNG/Vision roundtrip plus owned-file export; injected read-only Messages rows, expiry/error/cancel/confidential copy. No real Messages account/database or Screen Recording prompt used. |
| Package / Travel / Sports / Weather | Fixed-origin GET headers/queries, redirect/errors/cancellation, disconnected initialization, optional fields and actual native response fixtures. Aviationstack gate-only data renders; Sports supports live football games only. Real user account entitlements/keys remain acceptance. |
| Focus app hiding | Injected public hide/restore with a 32-instance ownership bound, original PID+launch-date identity, failed persistent recovery/relaunch and preview UI. Real running applications/session transitions remain acceptance. |
| Shelf rules / shelves / Inbox | Real copied files and chosen-folder preview/enable; automatic expiry to retained trash, relaunch Undo, persisted retry pause; cross-shelf/alias/ancestor originals, unknown children and retained-source protection. Explicit local coordinated Inbox writes establish this Mac only. |
| Plugins | Manifest validation, two real bundled samples, permission/sandbox denial, bounded execution/cancel, corrupt registry preservation and atomic publish. No claim of a security audit for every plugin/future platform. |
| Closed-notch / onboarding | All 45 IDs/order/visibility/onboarding; 15 editable priority kinds; processing precedence; new primary/secondary renders. Owned native Copy/Reveal controls expose reachable AXButton semantics and real accessibility presses route the exact displayed record once without also opening tools. |
| Existing tools | MediaRemote/lyrics/HUD/capture/devices/status/network, currency/world clocks/GitHub, real image/video/workflow transforms, retained native visibility, Quick Look, sync recovery and update rejection fixtures remain passing. Real accounts, devices and permission prompts remain acceptance. |

Sync schema **3** imports schemas **1/2** and shares independently versioned ordinary-text snippets, habits and shelf/rule definitions alongside prior portable libraries. Local credentials/codes/clipboard/file bytes/paths/bookmarks/Inbox settings/rule enablement stay local. Incoming changed rules require a new preview/Enable. Concurrent category variants retain explicit resolution, and failed multi-store applies preserve exact prior data or private recovery. All syncing Macs need the expanded schema-3 build.

Shelf expiry is off until an exact preview and Enable. Eligible owned copies move into retained Undo trash, including while hidden; Undo disables matching rules before restore. IO failures pause retries across relaunch until explicit Retry. Copied directories/unexpected contents lack a complete ownership inventory and are retained. There is no automatic trash purge. Indexed originals/references, canonical aliases and ancestor-directory references remain protected.

## Public provider evidence

The run records five account-free public responses and their production Swift decoder tests under `public-probes/`. AQI/UV/PM2.5 and eight consecutive 15-minute precipitation intervals use actual returned dates and values. Model thresholds are not official severe-weather warnings. Frankfurter retains the provider's actual rate date.

Official Aviationstack API reference and OpenAPI returned HTTP 200 in this run. The recorded server/path/access_key/flight_iata/limit/fields/time offsets match the client. Production decoding of the untouched published Aviationstack example passed independently during cloud evaluation and is outside the 395-test count. These document/sample checks do not establish an authenticated account, TLS plan entitlement or future timetable coverage. API-FOOTBALL documentation returned HTTP 403 in this run; its pinned official SDK confirms the origin/header/live-fixtures contract but its Teams file does not establish partial-name search. Search/plan compatibility requires the user's real account. AfterShip adapter documentation/fixtures cover the versioned header and read-only registered-shipment pages; no shipment registration/account API was called by evaluation.

## Native preview paths

All docs PNGs are copied unchanged from this run. Fixture names/captions identify injected data. Native rendering does not prove permission prompts, live accounts or physical placement.

- [Context](docs/NotchOrbitPlus-Context-disabled.png), [file proposals](docs/NotchOrbitPlus-AskOrbitFiles-fixture-preview.png), [Translate](docs/NotchOrbitPlus-Translate-fixture-unstarted.png), [dictation](docs/NotchOrbitPlus-Dictation-fixture-recognized-levels.png), [QR](docs/NotchOrbitPlus-QR-fixture-generated-and-decoded.png).
- [Snippets](docs/NotchOrbitPlus-Snippets-fixture-library.png), [habits](docs/NotchOrbitPlus-Habits-fixture-seven-weeks.png), [shelf rules](docs/NotchOrbitPlus-ShelfRules-fixture-disabled.png), [focus hiding](docs/NotchOrbitPlus-FocusAppHiding-fixture-preview.png), [gate-only travel](docs/NotchOrbitPlus-Travel-fixture-gate-without-terminal.png).
- [Download Reveal](docs/NotchOrbitPlus-Compact-fixture-primary-downloads.png), [code Copy](docs/NotchOrbitPlus-Compact-fixture-primary-verificationCode.png), [dictation waveform](docs/NotchOrbitPlus-Compact-fixture-primary-dictation.png), [command](docs/NotchOrbitPlus-Compact-fixture-primary-command.png), [weather](docs/NotchOrbitPlus-Compact-fixture-primary-weather.png).

## Performance and distribution

The Release harness checks three-second startup, warms up eight seconds, then measures eleven actual samples spanning ten intervals. Mean owned-process CPU uses cumulative CPU-time deltas; 100% means one CPU core. RSS converts KiB to decimal MB. Results are **0.715% CPU / 89.358 MB peak RSS**, below **3% / 250 MB**. This finite default-local idle run excludes WindowServer/GPU/other processes; no tool/account/permission/network/playback was enabled. Longer uptime, battery impact, every hardware model and physical interaction remain acceptance.

No Apple signing/notary credential bindings were configured. Strict ad hoc signing passes, but Developer ID/notarization/stapling and trusted same-team automatic installation remain unverified. Ad hoc packages use checksum-verified downloads/manual installation. Earlier 0.3 builds compare marketing versions only; install build 4 via this ZIP/manual replacement. The public stable feed matches this exact compiled source/package.

## Remaining physical Mac and account acceptance

- **Local models:** eligible macOS 26+ Apple Intelligence, downloaded Foundation Models, real summarization/table/screenshot naming, supported macOS 15+ Translation pairs/model preparation; Intel and macOS 14 runtime checks beyond successful universal/minimum-system metadata.
- **Consent and capture:** real grant/denial/revocation for Input Monitoring, Accessibility, Full Disk Access/Messages, Speech, Microphone, Screen Recording, Automation, camera, Calendar, Reminders, Bluetooth, Focus and Notifications. Real dictation final results/waveform/held shortcuts, screen area/window/display/Retina selection, protected content and short silent MOV playback.
- **Notch and keyboard:** physical notch/notchless and secondary-display geometry, Finder/file/app-pin drops, hover/click/pin/delay/menu fallback, per-display/Space/fullscreen/sleep behavior, busy-editor suppression/Context Undo, keyboard focus/navigation, VoiceOver, Reduce Motion, theme/accent/sound and installed Shortcuts/AppIntents discovery/execution.
- **Downloads and commands:** actual Chrome/Firefox/Safari partial naming/growth/rename and folder access, pause/resume/missed completions; Terminal/Xcode interruption/signals, Python 3 availability, helper permissions and start/finish continuity across hide/background/relaunch.
- **Hardware and status:** browser/player discovery/playback/artwork/lyrics/private MediaRemote restrictions, actual volume/mute/brightness keys/output displays, Mac/AirPods/peripheral batteries, mic/camera/authorized Focus state, changing interfaces/VPN and hardware/network sampling.
- **Accounts:** valid user keys/scopes/plans for AfterShip registered shipments, Aviationstack HTTPS/flights, API-FOOTBALL team search/live games, stocks, merchant sales and GitHub Actions; authenticated Codex CLI quota. Public HTTP/document examples and injected fixtures do not establish real account data. Live railway status remains unsupported; train countdowns are Calendar-derived.
- **Storage and recovery:** actual focus-hide/restore of chosen app instances, screenshot/folder shelf rules and retained Undo, chosen-folder access, two physical Macs/provider conflicts and schema-3 sync, iCloud Drive Orbit Inbox delivery to an iPhone, AirDrop/Quick Look, plugin grants/Seatbelt behavior on installed supported systems and longer performance/resource measurements.
- **Distribution:** launch-at-login, actual Developer ID signing, notarization/stapling/Gatekeeper and trusted same-team update/install/recovery with appropriate Apple credentials.

## Historical baseline

The earlier 31-tool 0.3.0 source `7dc43a6aec2a4d14657d41186c193b850dcfa43e` passed [run 37220531371](https://github.com/sknitd/orbit/actions/runs/37220531371): 37 shared, 129 Plus core and 123 native (**289 total**), 54 PNGs. Its immutable artifact `497ffa0672eadf61168e0974c99416086b0b2121` is historical; this expanded build has separate source/artifact provenance above.
