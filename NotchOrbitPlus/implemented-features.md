# NotchOrbitPlus implemented features

Version 0.3.0 keeps its own `com.sknitd.NotchOrbitPlus` identity, macOS 14 minimum and universal arm64/x86_64 output. OrbitDrop and NotchOrbit remain separate applications. Executed build evidence belongs in [EVALUATION.md](EVALUATION.md); this file describes source behavior.

## Media, HUD and capture

- Explicit System playback connection dynamically loads MediaRemote. Real metadata, artwork and supported controls feed the existing shared Now Playing store and closed-notch activity. Missing symbols, access restrictions, timeout and unavailable metadata produce errors; Music/Spotify Automation remains available.
- LRCLIB lookup is off by default and runs only when the user clicks Lookup. Requests send track metadata to LRCLIB, use bounded responses, validate timestamps and cancel on hiding/disconnection/track changes. Imported local LRC remains available.
- Optional volume/brightness key interception starts only from Enable, with explicit Accessibility consent. Only successfully adjusted supported keys are consumed. Disabled/denied/unsupported controls, modified keys and an unavailable notch presentation pass through to macOS.
- ScreenCaptureKit captures a selected area, window or display after explicit Screen Recording consent. Valid PNGs go into managed File Shelf storage even when ordinary shelf Auto-save is off. Optional Send to Workflow requires another explicit action.
- Short silent `.mov` recording uses ScreenCaptureKit streams and AVAssetWriter on macOS 14. Stop and Save ends recording; cancellation/hiding stops capture and removes partial output. Compress runs a saved video Workflow through the actual inherited native media engine, with smaller-output validation and optional ZIP. Image and video stages cannot be mixed.

## Additional dashboard tools

- Color Picker uses NSColorSampler only on Pick. It copies HEX/RGB/HSL/SwiftUI/NSColor formats, keeps local pick history and named validated sRGB palettes, and syncs palettes when configured.
- Devices reads available Mac/peripheral batteries from IOKit. Bluetooth connection is explicit; unknown batteries stay unknown. Optional background monitoring supplies real closed-notch device status.
- Status reads available CoreAudio input activity and camera-use information without starting capture. Explicit Connect Focus requests public Focus-status authorization and reads the optional shared state. Unavailable information is labeled. Optional background monitoring supplies actual active indicators.
- Network displays local interface traffic deltas, interface details and tunnel/VPN indicators. It uses no external network probe and handles counter resets/interface changes.
- Converter adds explicit-refresh currency conversion using existing OnlineFXRates and labels the provider's rate date.
- World Clock persists chosen zones, validates DST conversions and compares actual authorized Calendar meeting times without requesting Calendar access on appearance.
- GitHub Actions uses an app-specific Keychain token and explicit Connect/Refresh to read the user's repositories and workflow runs. Requests are GET-only, bounded and reject redirects; errors and pagination limits remain visible.
- Focus Stats charts a week of completed focus sessions from bounded persisted history. Legacy session counts do not invent historical dates or durations. Unreadable history is retained and backed up before an explicit replacement.

## Interaction and polish

- Every dashboard tool participates in visibility, order and onboarding selection. Hidden native views stop sampling/capture unless their explicit background-monitoring setting permits it.
- Closed-notch priorities are editable across processing, HUD, meetings, timers, music, devices and status. Invalid stored orders remain preserved and can be reset with a backup.
- Per-display enabled/width settings, All Spaces/Current Space placement, and opt-in fullscreen hiding are implemented. Fullscreen hiding reads the actual focused window's Accessibility fullscreen attribute and affects only its matching display.
- System/light/dark theme, accent colors and optional drop/workflow sound are local preferences, with portable appearance choices eligible for sync.
- Optional shared-folder sync adds logical launcher targets, workflow presets, palettes, appearance, priorities and world zones to notes/tasks/dashboard settings. Bookmarks, credentials and clipboard remain local. Synced folders require resolution on each Mac; concurrent variants remain available for explicit resolution. All syncing Macs need 0.3.0 for the new version-2 snapshots.
- Five AppIntents expose Start Focus, Add File to Shelf, Run Workflow, Toggle Dashboard and Capture Screenshot. File inputs are bounded and scoped; workflow output files can pass to the next Shortcut action.
- Dashboard Tab navigation, arrow-key tab navigation, Control-Tab/Control-Shift-Tab tool switching, Escape collapse, VoiceOver labels and Reduce Motion handling are implemented. Interactive assistive-technology acceptance remains separate.
- Smoke launch samples real idle CPU and RSS after warmup, records raw intervals/budgets in `idle-performance.json` and fails when the configured budget is exceeded.

No telemetry or cloud AI is added. Provider requests remain explicit; native permissions are requested only from user-started controls. See [known-limitations.md](known-limitations.md) for hardware and distribution constraints.
