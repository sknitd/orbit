# NotchOrbitPlus evaluation

This app is separate from NotchOrbit and OrbitDrop. Its twenty dashboard entries cover the nineteen explicitly named OmniNotch tools plus inherited file transformations. The public reference was captured through macOS CI on October 4, 2026; no proprietary code or branded assets were copied.

## Evidence in progress

The real SDK probe, [run 37196156380](https://github.com/sknitd/orbit/actions/runs/37196156380), used Xcode 26.6/macOS SDK 26.5 and compiled public FoundationModels for both arm64 and x86_64 at deployment target 14.0. Both binaries had a weak FoundationModels load command. Full app native compilation, tests, visual evaluation and packaging are still in progress.

Portable suites cover inherited activation/geometry/payload boundaries, deadline-based focus timers, unit conversion, shelf retention, local model persistence, local lyric parsing, Shortcut argument validation, provider response normalization, usage import validation and currency handling. Hosted tests cover actual native file transformations, pasteboard contracts and rendered dashboard modules. Final totals and packaged artifact provenance will be recorded after they pass.

## Feature scope and acceptance

The reference's marketing count is twenty; its visible text/HTML explicitly names nineteen. The app adds its existing File Actions as the twentieth entry. This is an independently implemented feature set with the following material differences:

- AI Usage supports explicitly selected normalized local usage reports; it does not automatically retrieve subscription session/weekly limits from tools already signed in. There is no universal documented public quota API for all five advertised services, and installed-tool credentials are not extracted.
- Now Playing supports Music and Spotify through public Automation. Synced lyrics require a real local timestamped LRC file. System-wide player discovery, browser playback and automatic lyrics are not claimed.
- Ask Orbit uses genuine weak-linked FoundationModels, requiring an eligible macOS 26+ Apple Intelligence configuration. Unsupported systems show availability information.
- Stocks uses an explicitly configured market-data provider; quote delay and intraday access depend on that provider's plan. Weather uses Open-Meteo, not a provisioned WeatherKit entitlement.
- Sales requires each user's read-authorized merchant credential. Provider schema decoding and currency logic can be tested with synthetic fixtures; real accounts, scopes, complete paging and totals require connected-account verification.

Interactive acceptance must be performed on a real Mac: physical-notch and notchless layouts, Retina/secondary displays, hover/click/delay, Cmd-Control-N, pinning and order/hiding settings, camera start/stop/permission denial, Music/Spotify controls and imported lyrics, Calendar and Reminders permission/read/write, AirDrop recipient flow, file-shelf retention, clipboard confidential marker handling, deadline recovery after sleep, teleprompter scroll, installed shortcut execution, and online-provider refresh/error/rate-limit behavior. Measure idle CPU/memory, dashboard responsiveness, VoiceOver, Reduce Motion, Spaces and fullscreen behavior. Automated rendering and startup checks do not establish these results.

The development app will use an ad hoc signature. Developer ID signing and Apple notarization are not available from the repository's current credentials.
