# NotchOrbitPlus evaluation

NotchOrbitPlus is separate from NotchOrbit and OrbitDrop. Its 22 dashboard entries comprise the nineteen explicitly named OmniNotch reference areas, inherited File Actions, Quick Launcher and Workflows. The public reference was inspected on October 4, 2026; no proprietary code or OmniNotch branded assets were copied. The comparison records implemented scope, not complete parity with the reference product.

## Verified build

[Run 37209047295](https://github.com/sknitd/orbit/actions/runs/37209047295) succeeded for source `c7ed6f4a36342ea1ec6fb7a57eefab0c67aef7ce`. The immutable [artifact commit](https://github.com/sknitd/orbit/tree/33b34fdbbdb8770046b69861aa1f0ea375338aec) contains the app ZIP, checksum, build status, complete logs, SDK inventory, package verification, public responses and all 30 native PNGs.

| Check | Result |
| --- | --- |
| Shared portable core | 37 passed |
| NotchOrbitPlus portable core | 84 passed |
| Hosted native tests | 59 passed, zero failures/skips |
| Total | **180 passed** |
| Build SDK | Xcode 26.6 / macOS SDK 26.5 / Swift 6.3.3; arm64 macOS 26 runner |
| Release package | Version 0.2.0; `com.sknitd.NotchOrbitPlus`; arm64 and x86_64 |
| Minimum OS | macOS 14.0 in the plist and both Mach-O slices |
| FoundationModels | Public API compiled; actual weak load command in both slices |
| Signing/startup | Strict ad hoc signature verification and three-second Release startup passed |
| Native renders | 22 actual dashboard views at 560×440, five labeled compact fixtures, onboarding/update settings at 560×560, and the inherited file-action semicircle |
| Public services | Open-Meteo city search/forecast and Frankfurter USD rates: three HTTP 200 responses decoded by production Swift models |
| Published updates | Anonymous stable feed and its archive returned HTTP 200; source, size and SHA-256 matched this CI package |

The 6,470,829-byte [ZIP](https://github.com/sknitd/orbit/raw/33b34fdbbdb8770046b69861aa1f0ea375338aec/NotchOrbitPlus.app.zip) has SHA-256 `c667dc2a5111db1255659503863c8af673753d13ea31c9737ca8bb6e83d0f280`. Independent retrieval checked ZIP integrity, executable permissions, bundle identity/resources, both architectures, deployment commands and weak FoundationModels links. Signing and startup results come from the actual macOS runner. Linux cannot perform these Darwin checks. Intel and macOS 14 runtime acceptance was not separately performed.

Independent visual review checked the native dashboard and compact captures. Setup captures retain the actual native window background; they are not edited composites. Compact music/meeting/progress states use clearly labeled fixtures, not connected user accounts. Rendering and startup do not establish physical-notch behavior.

## Evidence for the additions

| Addition | Executed evidence and practical limit |
| --- | --- |
| Live notch status and meetings | Core priority/countdown/link validation; four native tests exercise actual EventKit event projection, explicit Join, unsafe/open-failure handling and five compact states. No real user calendar or playback account was connected. |
| Quick Launcher | Three native tests resolve real folder/application bookmarks, report missing targets and reject invalid app pins without launching them. Portable tests validate stored pins and Shortcut identifiers. |
| Saved drop workflows | Nine native tests run real resize/conversion/compression/batch-ZIP engines, decode results, verify collision handling and preserve sources through cancellation, partial failure, symlinks and concurrent replacement. Physical Finder drop remains manual acceptance. |
| File Shelf | Metadata migration/search/favourites tests and a real Quick Look panel test verify selected-file ownership and responder restoration; managed-copy tests preserve original bytes. |
| Clipboard OCR | Four native tests recognize actual image text, search/copy it, reject invalid/oversized images and cancel without resurrecting deleted history. Existing pasteboard/confidential-marker/opt-in tests also pass. |
| Optional sync | Causal-merge/settings tests and eight native coordinated-file tests exercise two device identities, corrupt/oversized files, symlinks, concurrent publication and local-data preservation. Two physical Macs and cloud-provider delivery were not tested. |
| First-run setup and updates | Actual onboarding/update views render without invoking setup actions. Four native production HTTP-client tests use isolated transport fixtures for streamed ZIP verification, checksum/size/HTTP failures and cleanup. A native installer test rejects an unsigned candidate without replacing the running app. The published public channel/archive were separately fetched and verified. Trusted signed installation and notarization remain unverified. |

Sync is off until a shared folder is selected and enabled. It shares notes, tasks and an allowlist of dashboard/opening settings; account credentials, clipboard, shelf files and launcher bookmarks stay local. Folder data is readable to whoever can access that folder. Cross-Mac delivery depends on the chosen folder provider.

All update automation starts off. This ad hoc build can check/download verified updates for manual installation. Automatic installation requires a trusted Developer ID signed running application and a same-team notarized update. The signing/notarization pipeline is implemented, but the CI credential-presence report confirms Apple signing/notary credentials are absent. This package is **not notarized**.

## Remaining scope and Mac acceptance

- AI Usage supports explicit live Codex quota through a selected installed CLI's documented `account/rateLimits/read` protocol. Other providers use normalized imported reports. Native subprocess tests validate the handshake and cancellation with fixtures, not authenticated subscription reads. No model/thread/turn/tool calls or credential extraction occur.
- Now Playing supports Music/Spotify through Automation and imported timestamped LRC lyrics. System-wide discovery, browser playback and automatic lyrics are not implemented.
- Ask Orbit uses weak-linked FoundationModels and requires eligible macOS 26+ Apple Intelligence. Model inference on eligible hardware remains untested.
- Stocks requires the user's Alpha Vantage credential and plan. Public weather and FX were verified; credentialed stock refresh was not. FX preserves the provider's returned rate date.
- Sales has seven read-only adapters and schema/currency tests, but real account credentials/scopes/totals are unverified. It labels current UTC creation-day gross paid amounts, available order-attached refunds, ten-page coverage and dated USD conversion; these are not net revenue or refunds processed today.

Real-Mac acceptance remains for physical-notch/notchless and secondary-display geometry; Finder dragging; hover/click/delay and keyboard toggle; camera, Calendar, Reminders and Automation consent; Music/Spotify playback; AirDrop/Quick Look interactions; installed app/Shortcut launching; two-Mac sync and provider conflicts; login registration; notarized updates and recovery; sleep/Spaces/fullscreen; VoiceOver/Reduce Motion and idle CPU/memory. Each Mac needs its own permission grants and integration setup. Native rendering, temporary-file tests and startup smoke do not establish these results.
