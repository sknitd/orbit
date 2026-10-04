# NotchOrbitPlus evaluation

NotchOrbitPlus is separate from NotchOrbit and OrbitDrop. Its twenty dashboard entries cover the nineteen explicitly named OmniNotch tools plus inherited file transformations. The public reference was captured through macOS CI on October 4, 2026; no proprietary code or OmniNotch branded assets were copied.

## Verified build

[Run 37198489083](https://github.com/sknitd/orbit/actions/runs/37198489083) succeeded for source `872ea4eab4fbec98d81d622b6100d41cdf5a71ab`. The immutable [artifact commit](https://github.com/sknitd/orbit/tree/fd634cffb5e5cdac27235355dcaef539de6350fb) contains the app ZIP, checksum, build status, complete logs, SDK inventory, package verification, public responses and all 21 native PNGs.

| Check | Result |
| --- | --- |
| Shared portable core | 37 passed |
| NotchOrbitPlus portable core | 54 passed |
| Hosted native tests | 24 passed, zero failures/skips |
| Total | **115 passed** |
| Build SDK | Xcode 26.6 / macOS SDK 26.5 / Swift 6.3.3; arm64 macOS 26 runner |
| Release package | Version 0.1.0; `com.sknitd.NotchOrbitPlus`; arm64 and x86_64 |
| Minimum OS | macOS 14.0 in the plist and both Mach-O slices |
| FoundationModels | Genuine public API compiled; actual weak load command in both slices |
| Signing and startup | Strict ad hoc signature verification and three-second startup check passed |
| Native renders | Twenty actual dashboard tool views at the 560-point minimum width plus the file-action semicircle |
| Public HTTP checks | Open-Meteo city search and seven-day forecast, and Frankfurter USD rates: three HTTP 200 responses, decoded by production Swift models |

The 5,122,034-byte [ZIP](https://github.com/sknitd/orbit/raw/fd634cffb5e5cdac27235355dcaef539de6350fb/NotchOrbitPlus.app.zip) has SHA-256 `e478befe9db4cc4bd4d171c3378015c204a4c62acd19366945a96e6f9fb05e4a`. Its identity, resources, architecture/deployment commands and weak FoundationModels links were independently inspected after retrieval. Darwin signing and launch results come from the actual macOS runner; Linux cannot execute those checks. Intel and macOS 14 runtime acceptance was not separately performed.

Portable tests cover inherited activation/geometry/payload boundaries, deadline-based focus timers, conversion, shelf retention and local models, lyric timestamps, safe Shortcut arguments, CPU/network deltas, provider normalization, usage validation, public weather/stock schemas, dated foreign-exchange conversion and Codex quota windows.

Native tests exercise genuine image/file transformations, named pasteboards and confidential-marker/image/link handling, clipboard opt-in and hidden lifecycle, and managed shelf copies that preserve original file bytes. Dashboard tests instantiate the production twenty-module factory, check settings/order/visibility, safe display geometry and suspension, validate all 3,944 official Unicode emoji and licenses, and render the real native views. Independent visual review found collapsed editor/list viewports; the final captures confirm usable Quick Note, Clipboard, To-Dos and File Shelf areas, including a visible empty shelf drop target. All twenty final dashboard captures use the minimum 560-point setting; older narrower preferences are clamped to keep provider tools inside the panel.

Three native Codex tests launch actual temporary subprocesses and verify the exact documented initialization/quota handshake, closed-input error without SIGPIPE termination, and cancellation that terminates only the owned child. The strict closed-channel test passed in 0.098 seconds, handshake in 0.135 seconds and cancellation in 0.386 seconds. These are protocol fixtures, not authenticated subscription reads or model calls.

The public probes used Berlin coordinates without account credentials at `2026-10-04T11:22:30.563322+00:00`. Frankfurter's returned rate date was `2026-10-02`, retained explicitly rather than represented as today's trading rates. All three native production-decoder checks ran and passed; none were skipped.

## Feature scope and remaining acceptance

The reference's marketing count is twenty; its visible text/HTML explicitly names nineteen. The app adds its existing File Actions as the twentieth entry. These material differences remain:

- AI Usage supports an explicit live Codex quota read through the installed CLI's documented `account/rateLimits/read` protocol, with initialization only and no model/thread/turn/tool calls. Other providers use selected normalized local reports. Automatic signed-in account collection for Claude, Cursor, Copilot and Grok is not implemented; credentials are not extracted. The protocol is pinned to public `openai/codex` commit `afb436df8b70bb5bc57b86d9a3e829968988cd21`. Live user-account acceptance remains pending.
- Now Playing supports Music and Spotify through public Automation. Synced lyrics require a local timestamped LRC file. System-wide player discovery, browser playback and automatic lyrics are not claimed.
- Ask Orbit uses genuine weak-linked FoundationModels and requires an eligible macOS 26+ Apple Intelligence configuration. Unsupported systems show availability information. Model inference on eligible hardware remains untested.
- Stocks requires the user's Alpha Vantage credential; quote delay and intraday access depend on its plan. Weather uses Open-Meteo rather than WeatherKit. Public weather and FX were verified; credentialed stock refresh was not.
- Sales requires each user's read-authorized merchant credentials. Seven real read-only adapters and schema/currency fixtures are implemented, but authenticated accounts, scopes, complete pagination and merchant totals remain unverified. The UI labels current UTC creation-day gross paid amounts, available order-attached refunds, bounded ten-page coverage, dated USD conversion and missing currencies. These are not net revenue or refunds processed today.

Interactive acceptance must be performed on a real Mac: physical-notch/notchless layout, Retina/secondary displays, hover/click/delay, Cmd-Control-N, pinning and tool order/hiding, camera start/stop/permission denial, Music/Spotify controls and imported lyrics, Calendar permission/event reads, Reminders permission/reads/completion, AirDrop recipients, shelf retention and dragging, clipboard confidential sources, sleep recovery, teleprompter scrolling, installed shortcut execution and provider refresh/errors/rate limits. Measure idle CPU/memory, responsiveness, VoiceOver, Reduce Motion, Spaces and fullscreen behavior. Native rendering, temporary-file tests and startup smoke do not establish these results.

The app is ad hoc signed and not notarized. Developer ID signing and Apple notarization are unavailable from current repository credentials. Each Mac requires its own permission grants and provider setup.
