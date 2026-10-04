# NotchOrbitPlus

A separate native Mac app copied from NotchOrbit, with an expanded notch dashboard and the original key-free file-action semicircle. Hover or click the compact strip to open tools; pin the dashboard while working. On a Mac without a notch, it uses the display's top center.

The [OmniNotch reference page](https://omninotch.app/) inspected on October 4, 2026 advertises twenty tools but explicitly names nineteen. This app implements those nineteen named tool areas under its own Orbit identity, plus NotchOrbit's existing File Actions. It has its own `com.sknitd.NotchOrbitPlus` bundle identifier, preferences, storage, project and build output. NotchOrbit and OrbitDrop remain separate apps.

## Install and open

[**Download NotchOrbitPlus.app.zip**](https://github.com/sknitd/orbit/raw/fd634cffb5e5cdac27235355dcaef539de6350fb/NotchOrbitPlus.app.zip) · [SHA-256 checksum](https://github.com/sknitd/orbit/blob/fd634cffb5e5cdac27235355dcaef539de6350fb/NotchOrbitPlus.app.zip.sha256)

The universal app targets **macOS 14 or later**, on Apple Silicon and Intel. Developer tools are not needed to run it. If this repository is private, sign in to GitHub with access before downloading.

1. Extract `NotchOrbitPlus.app.zip`, move the entire app to Applications, and open it.
2. Hover or click the compact strip below the notch. **⌘⌃N** toggles the dashboard without observing other typing. Pin it to keep it open.
3. Use Settings to choose hover/click opening, delay, width (560–800 points), display, tab order and visible tools.
4. Enable Input Monitoring only if you want automatic Finder-drag file actions. Calendar, Reminders, Mirror and Now Playing request their own permissions when you connect or start them.
5. Clipboard history starts only after you enable it. Connected tools provide explicit Refresh/Connect controls and display errors rather than invented data.

The development app is ad hoc signed and **not notarized**. If macOS blocks it, try opening it, then use System Settings → Privacy & Security → Open Anyway if offered. Each Mac needs its own permission grants and integration setup. Developer tools are not required to run the packaged app.

This is version **0.1.0**, built from source `872ea4eab4fbec98d81d622b6100d41cdf5a71ab` by [macOS CI run 37198489083](https://github.com/sknitd/orbit/actions/runs/37198489083). All **115 tests passed**: 37 shared core, 54 NotchOrbitPlus core and 24 hosted native tests, with no failures or skips. Universal Release compilation, strict signature verification and startup checks passed. Native tests rendered all twenty dashboard tools; public weather and foreign-exchange responses were fetched and decoded successfully. See [EVALUATION.md](EVALUATION.md) for evidence and remaining Mac/account checks.

ZIP SHA-256:

```text
e478befe9db4cc4bd4d171c3378015c204a4c62acd19366945a96e6f9fb05e4a
```

## Tools and requirements

| Tool | What it does | Setup or practical limit |
| --- | --- | --- |
| Ask Orbit | On-device chat, rewrite and summarize using Apple Foundation Models | **macOS 26+**, compatible Apple Silicon, enabled Apple Intelligence and downloaded model; no cloud fallback |
| AI Usage | Live Codex quota through a selected installed Codex CLI; imported session/weekly reports for Claude, Codex, Cursor, Copilot and Grok | Live read uses Codex's documented account-only protocol; other providers use imported snapshots, with actual timestamps/limits |
| Sales | Read-only adapters for Stripe, Shopify, Lemon Squeezy, Gumroad, Dodo, Polar and Paddle; recent paid orders, grouped-currency amounts and dated USD conversion | User credentials in this app's Keychain; current UTC creation-day gross paid amounts, available order-attached refunds and ten-page cap are labeled; real-account verification required |
| Clipboard | Search/filter text, links, images and files; re-copy, delete and clear retained clips | Explicit opt-in, bounded local history; skips recognized confidential/transient markers, which cannot identify every secret |
| Teleprompter | Auto-saved script with import, play/pause, restart, speed and text-size controls | Keep the dashboard open/pinned while reading |
| Timers | Focus/break countdowns, pause/resume, completed sessions, optional automatic breaks and soft focus sound | Deadline survives hiding/sleep; remaining time appears in the closed dashboard |
| File Shelf | Drop/reveal/drag/share files, native AirDrop, optional managed copies and retention | Open File Shelf before dropping; retention removes managed copies, never original sources; AirDrop uses Apple's recipient picker |
| Mirror | Live camera preview | Explicit Start and camera consent; video only; stops when hidden |
| Calendar | Month/day navigation and real Apple Calendar events | Explicit full-access Calendar consent |
| Reminders | View and complete real Apple Reminders | Explicit full-access Reminders consent |
| To-Dos | Persistent local tasks, completion and stars | Independent of Apple Reminders |
| Weather | City search, current conditions and seven-day forecast | Open-Meteo network connection; user-chosen city, no location permission |
| Stocks | Quotes and intraday charts for selected tickers | User-provided Alpha Vantage key; provider plan, rate limits and data delay apply |
| Emoji | Search/filter/copy/drag **3,944 fully qualified Unicode 17 emoji** | Versioned official Unicode catalog, with license and provenance; native character palette also available |
| Converter | Live length, mass, temperature, volume and speed conversion | Works locally, including temperature offsets and absolute-zero validation |
| System | Real CPU, memory, disk, network and battery statistics | Samples while visible; desktop Macs may have no battery |
| Quick Note | Auto-saved local note | Oversized/unreadable existing notes are preserved; replacement creates a backup |
| Now Playing | Supported-player metadata/artwork and playback controls; synced lyrics from local LRC files | Music or Spotify connection with Automation consent; no universal browser/player capture or automatic lyrics service |
| Shortcuts | List and run installed macOS Shortcuts | Explicit chosen shortcut; macOS may request the shortcut's own permissions |
| File Actions | Original NotchOrbit contextual image/PDF/media/archive/text transformations | Drag a local file toward the notch without keys; a real drop on a labeled action authorizes processing |

The feature comparison describes implemented tools and their setup, not verified access to a user's camera, calendars, merchant accounts or AI subscription. Interactive and connected-account acceptance is recorded separately in [EVALUATION.md](EVALUATION.md).

## Data and privacy

Notes, tasks, retained clipboard, shelf data, teleprompter scripts and imported usage reports stay in this app's local storage. Clipboard is opt-in; clear retained history when appropriate. Managed shelf copies can be removed by the selected retention rule; originals are preserved. Camera capture and system/player sampling stop when their tool is hidden.

Weather, stocks, merchant integrations and foreign-exchange lookup contact their respective providers when you request data. Provider credentials are stored in this app's macOS Keychain namespace, not in preferences or source. Use keys with read-only permissions where the provider supports them. There is no telemetry or remote AI fallback. AI Usage does not inspect sign-in caches or extract credentials: its explicit live Codex read lets your selected, already signed-in CLI handle its own authentication. It performs no model, thread, turn or tool call and records only reported quota windows.

## Build

On a Mac with **Xcode 26 or later**, CMake, Python 3 and Git:

```bash
bash NotchOrbitPlus/Scripts/build.sh
open NotchOrbitPlus/build/DerivedData/Build/Products/Release/NotchOrbitPlus.app
```

The app keeps a macOS 14 minimum while weak-linking FoundationModels for eligible macOS 26 systems. Building with an older SDK is rejected so the AI feature is not silently omitted. The script runs portable/native tests, builds both architectures, verifies signing and startup, and writes `NotchOrbitPlus/dist/NotchOrbitPlus.app.zip` and its SHA-256 checksum.

Portable tests on the cloud Linux environment:

```bash
bash NotchOrbitPlus/Scripts/cloud-core-tests.sh
```

The independent workflow `.github/workflows/notchorbitplus.yml` uses a real macOS 26/Xcode 26 runner and publishes status, logs, previews and successful app packages on `codex/notch-plus-builds/run-<id>-<attempt>` branches for Git-only retrieval.

## Native previews

These are captures of the actual native panels from the verified build. They show the dashboard's converter, file shelf and note editor, followed by the inherited file-action semicircle. Interactive Finder dragging and physical-notch placement still need Mac acceptance.

![Converter in the NotchOrbitPlus dashboard](docs/NotchOrbitPlus-Dashboard-converter.png)

![File Shelf with its visible native drop area](docs/NotchOrbitPlus-Dashboard-fileShelf.png)

![Quick Note multiline editor](docs/NotchOrbitPlus-Dashboard-quickNote.png)

![NotchOrbitPlus native file-action semicircle](docs/NotchOrbitPlus-Convert.png)
