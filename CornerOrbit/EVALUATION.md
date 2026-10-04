# CornerOrbit evaluation

The [final macOS workflow](https://github.com/sknitd/orbit/actions/runs/37239008254) passed on 2026-10-04 using Xcode 16.4, Swift 6.1.2 and the macOS 15.5 SDK on an Apple silicon runner. It executed **77 unique tests**, produced 12 native preview captures, built a universal release and verified the packaged app's launch and signature.

## Executed tests

| Suite | Passed | Evidence covered |
| --- | ---: | --- |
| CornerCore portable tests | 36 | All 20 bindings, strict settings/URL validation, corner geometry, click disambiguation, drag thresholds, modifiers, cooldown, display separation and history sanitization. |
| Native action tests | 8 | Fixed document/tab scripts, explicit Automation gating, installed desktop targets, missing-app errors, safe URL routing, script timeout/cancellation and real built-in-only script execution. |
| Native app store and persistence | 7 | Queued/late action cancellation, settings edits, Automation disable, shutdown, private staging, failed publication, corrupt configuration and symlink preservation. |
| Independent native evaluation | 6 | Data-only assignment/preset behavior, permission denial, no startup prompts, actual routing, error retention, successful-only opt-in recents, settings/editor/popover rendering. |
| Native gesture adapter | 7 | Quartz/AppKit conversion, all corners, click/drag translation, display changes, pending-action cancellation, modifiers/session transitions and an actual one-shot deadline. |
| Native Chrome history | 13 | Real private SQLite fixtures, committed live WAL reads, missing SHM recovery, unchanged DB/WAL bytes, safe parent aliases, refused final symlinks, schema/corruption/size/busy handling and connection/recent lifecycle. |
| **Total** | **77** | **Zero failures; 41 hosted native tests plus 36 portable tests.** |

`bash CornerOrbit/Scripts/cloud-core-tests.sh` also passed all 36 portable tests on Linux with Swift 6.2 after the final implementation. These are the same 36 cases, not an additional set of unique tests. No real Chrome profile, Office account or OS permission grant was used by the fixtures.

The native run exposed and resolved an icon-helper actor isolation error, an unavailable Apple SQLite API, and the macOS `/var` alias behavior. The final reader passes a POSIX canonical parent path directly to SQLite, keeps `READONLY`/`NOFOLLOW`, refuses a symlinked final History file and verifies file identity. The recovery UI also leaves Clear/Disconnect available for unreadable saved website state.

## Native interface evidence

All 12 PNGs in [docs/](docs/) come from actual AppKit windows and popovers containing the production SwiftUI views. They cover the four-corner overview, each other selected corner, Behavior, Websites, Getting Started, the custom-website editor, an Input Monitoring denial, an action error and both website dropdowns. Synthetic entries are explicitly labeled in fixture captures; production never inserts those entries.

The independent evaluator inspected the captures for clipping and readability. All five binding rows fit with each selected corner; errors wrap visibly; the editor and dropdown actions are readable. Behavior uses a scroll view for its additional display and access controls. These captures do not prove physical mouse input, VoiceOver operation or TCC permission dialogs.

## Package and launch evidence

- `CornerOrbit.app` v0.1.0, bundle `com.sknitd.CornerOrbit`, with exactly **arm64 and x86_64** executable slices. Both Mach-O load commands declare **macOS 14.0** as the minimum.
- Strict ad hoc signature verification passed on macOS. The release ZIP contains no XCTest bundle/framework. It is **not Developer ID signed or notarized**.
- The ZIP's CRC, bundle metadata, executable architecture and icon were checked; an anonymous public download matched SHA-256 `881613151aa1c1e366610d1c9fa78ac53cb22e7b5628cf8f4c8951c72574c390` (1,239,876 bytes).
- The Release app stayed running through startup and 11 idle samples. Measured mean CPU was **0.09254%** and sampled peak RSS **47.26784 MB**, below the configured 3% / 250 MB limits.
- This finite idle check used `--smoke`: actual menu bar, isolated preview defaults, monitoring disabled, no preferences window or target-app action. It excludes WindowServer/GPU memory and does not establish active gesture performance or performance on every Mac.

Machine-readable evidence: [independent agent audit](docs/independent-evaluation.json), [validation summary](docs/validation-summary.json), [package metadata](docs/package-metadata.json), [SDK inventory](docs/sdk-inventory.json), [binary metadata](docs/binary-metadata.json), [signature](docs/code-signature.txt) and [idle samples](docs/idle-performance.json). Full logs and ZIP are retained in the immutable [result commit](https://github.com/sknitd/orbit/tree/b43e13edb99503527d37639a792f7fa01bca6ae2).

## Source provenance and isolation

The compiled full-repository source is `2924103225aaa0de37ea45c8ba55a0b4e5c3f3ed`; its independent CornerOrbit tree was built as `99ee9ed0123322a4785442afb1006a5eaca555ac`. Later changes add documentation and captured evidence only. The result commit is `b43e13edb99503527d37639a792f7fa01bca6ae2`.

The scope audit compares the complete tracked tree with immutable baseline `3b8647749e770c85e6faa9cf34e65bfe4a2d6242`. All additions are under `CornerOrbit/`; existing OrbitDrop, NotchOrbit, NotchOrbitPlus, root documentation and root workflows are unchanged. An isolated subtree branch provides Mac CI without editing those workflows.

## Remaining physical Mac acceptance

- Install the downloaded, quarantined app on macOS 14 and on an Intel Mac; verify Gatekeeper recovery and real Input Monitoring grant/revoke/restart behavior.
- Exercise all corners with mouse and trackpad single/double/triple clicks and both drag directions, including selected modifiers, cooldown and interactions with macOS Hot Corners/underlying apps.
- Exercise actual Chrome tab creation and each Office/TextEdit document action, including Automation denial, first-run/license dialogs and installed ChatGPT/Claude/Spotify targets.
- Connect a real Chrome profile with live browsing, multiple profiles, a locked database and any applicable macOS file-access restriction. The automated tests use private temporary SQLite fixtures only.
- Check multiple/Retina displays, disconnect/reconnect, negative arrangements, Spaces, fullscreen, sleep, fast user switching and screen-lock event ordering.
- Check full keyboard and VoiceOver interaction, appearance/Reduce Motion, active monitoring CPU and normal first-run UI memory on physical hardware.

These remaining checks are also recorded in [known-limitations.md](known-limitations.md); none are claimed as executed by the CI fixtures.
