# Known limitations

- The genuine Mac runner build passed 77 unique tests and produced a universal app. Linux can only execute the portable logic tests. The build uses an ad hoc signature and is not notarized; physical macOS 14 and Intel launch acceptance remains open.
- Input Monitoring prompts, live mouse/trackpad behavior, screen lock notification order, Spaces/fullscreen, scale changes and multi-display placement need interactive physical Mac acceptance. Public session notifications cancel known transitions; a fixture cannot prove every lock-screen ordering.
- macOS Hot Corners and underlying applications still receive input. The app does not suppress their behavior. Single and double actions intentionally wait for click disambiguation.
- Office apps, Chrome, ChatGPT, Claude and Spotify must be installed. Office licensing/first-run dialogs and real Automation prompts must be exercised on a Mac. No browser fallback is substituted for the ChatGPT or Claude desktop apps.
- Chrome history schemas, live profile access and macOS file access restrictions need a real Chrome profile acceptance check. Fixture tests use private temporary databases only. Read-only SQLite may maintain its transient shared-memory lock/index sidecar; it never writes history records.
- Recent Websites means successful websites opened through CornerOrbit after opt-in, not the user's complete browser session or all recent Chrome tabs.
- Website dropdowns attach to the menu bar icon. No browser content, tab titles or history is monitored in the background.
- Display UUIDs are used when available. The explicitly labeled fallback display ID is session-specific; unplug/replug behavior needs physical acceptance.
- The idle check measures the app process in a clean, disabled configuration on a CI Mac. It excludes WindowServer/GPU and does not characterize sustained event capture or every Mac model.
