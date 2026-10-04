# NotchOrbitPlus

A separate native Mac app with a notch dashboard and the original key-free file-action semicircle. Hover or click the compact strip to open tools; pin the dashboard while working. Macs without a notch use the display's top center.

The current source has **45 dashboard tools**. Its **14 new tools** are Context Rules, Downloads, Commands, Snippets, Translate, Dictation, QR, 2FA Codes, Package Tracker, Habits, Travel Status, Sports Scores, Search and Plugins. Ask Orbit gains local file proposals; Clipboard gains text transforms; File Shelf gains collections, rules and a chosen-folder Orbit Inbox; Weather gains air quality and precipitation detail. The app retains its own `com.sknitd.NotchOrbitPlus` identity, preferences and storage. NotchOrbit and OrbitDrop remain separate apps.

**Expansion verification is pending:** the download and evidence below remain the verified **0.3.0, 31-tool build**. The 45-tool table describes current source, and does not imply that the linked package contains the expansion. New native test results and previews will be recorded after the expanded macOS build succeeds.

The [OmniNotch reference page](https://omninotch.app/) inspected on October 4, 2026 advertises twenty tools and explicitly names nineteen. This app implements those nineteen named areas under the Orbit identity, inherited File Actions, Quick Launcher and Workflows, and the additional tools listed below. See [implemented-features.md](implemented-features.md) and [known-limitations.md](known-limitations.md) for source scope and practical limits.

## Install and open

[**Download NotchOrbitPlus.app.zip**](https://github.com/sknitd/orbit/raw/497ffa0672eadf61168e0974c99416086b0b2121/NotchOrbitPlus.app.zip) · [SHA-256 checksum](https://github.com/sknitd/orbit/blob/497ffa0672eadf61168e0974c99416086b0b2121/NotchOrbitPlus.app.zip.sha256)

**Verified macOS build:** 289 tests passed, a universal Release app was built, strict ad hoc signature verification and startup passed, and the ZIP/checksum were independently checked. The package is **not notarized**; hardware, permissions and connected accounts still need acceptance on your Mac.

The universal app targets **macOS 14 or later**, on Apple Silicon and Intel. Developer tools are not needed to run the packaged app. If this repository is private, sign in to GitHub with access before downloading.

1. Extract `NotchOrbitPlus.app.zip`, move the entire app to Applications, and open it.
2. Hover or click the compact strip below the notch. **⌘⌃N** toggles the dashboard without observing other typing. Pin it to keep it open.
3. First-run setup lets you choose visible tools, optional drag access, launch at login and automatic update checks. Settings controls opening behavior, delay, tool order, per-display placement/width, appearance and compact-status priorities.
4. Enable Input Monitoring if you want automatic Finder-drag file actions. Connected tools request their own access only when you choose Connect, Enable, Pick or Start.
5. Clipboard history, background monitoring, HUD interception, lyrics lookup, sync and update automation have explicit opt-in controls. Unavailable data and API failures remain visible.

Development packages are ad hoc signed and **not notarized** unless the configured Apple signing pipeline produces a trusted release. If macOS blocks an ad hoc app, try opening it, then use System Settings → Privacy & Security → Open Anyway if offered. Each Mac needs its own permission grants and integration setup.

The verified 0.3 evidence records source `7dc43a6aec2a4d14657d41186c193b850dcfa43e`, [macOS CI run 37220531371](https://github.com/sknitd/orbit/actions/runs/37220531371), artifact commit `497ffa0672eadf61168e0974c99416086b0b2121`, **123 hosted native tests**, **289 total tests** and **54 native previews**. ZIP size: **8,414,997 bytes**. See [EVALUATION.md](EVALUATION.md) for executed checks and remaining physical-Mac acceptance.

ZIP SHA-256:

```text
f258c6fa17c303a088759cd87e6aa12035e451151aabb6cc7afef30c8f3b89fa
```

## Tools and requirements

| Tool | What it does | Setup or practical limit |
| --- | --- | --- |
| Assistant / Ask Orbit | On-device chat; summarize readable text/PDF/Markdown, extract CSV, propose filenames and batch screenshot names | **macOS 26+**, eligible Apple Intelligence and downloaded model; editable preview and explicit confirmation create copies beside originals; no cloud fallback |
| AI Usage | Explicit live Codex quota through a selected installed Codex CLI; imported reports for Claude, Codex, Cursor, Copilot and Grok | Codex handles its own authentication; imported snapshots show reported limits/timestamps; no universal subscription-quota API is claimed |
| Sales | Read-only Stripe, Shopify, Lemon Squeezy, Gumroad, Dodo, Polar and Paddle adapters; recent paid orders, grouped currencies and dated USD conversion | Credentials in this app's Keychain; UTC creation-day gross paid amounts, available order-attached refunds and ten-page coverage are labeled; real-account acceptance remains |
| Clipboard | Search/filter retained clips, local image OCR and explicit JSON/URL/Base64/case/line transforms | History is opt-in; text transforms work without history; private/transient markers are skipped, but cannot identify every secret |
| Teleprompter | Auto-saved script, import, scrolling, speed and text-size controls | Keep the dashboard open/pinned while reading |
| Timers | Focus/break countdowns, pause/resume, optional sound and chosen-app hiding during focus | Preview and Enable app hiding explicitly; pause/end/disable restores only app instances this feature hid; never quits apps |
| File Shelf | Named shelves, drop/reveal/share/AirDrop, tags, Quick Look, previewed rules/cleanup and Orbit Inbox | Originals remain intact; owned-copy removal has persistent Undo; folder rules and Inbox require local choice plus Enable |
| Mirror | Live camera preview | Explicit Start and camera consent; video only; stops when hidden |
| Calendar | Real events, next-meeting countdown and Join from supported event links | Explicit Calendar consent; closed-notch meeting status has its own opt-in |
| Reminders | View and complete real Apple Reminders | Explicit full-access Reminders consent |
| To-Dos | Persistent tasks, completion and stars | Optional sync preserves deletion tombstones and concurrent edits |
| Weather | Chosen-city conditions/forecast, US AQI/UV/PM2.5 and eight 15-minute precipitation intervals | Explicit Open-Meteo refresh; optional 15-minute background checks; model thresholds are not official severe-weather warnings |
| Stocks | Quotes and intraday charts for selected tickers | User Alpha Vantage key; provider plan, rate limits and data delay apply |
| Emoji | Search/filter/copy/drag **3,944 fully qualified Unicode 17 emoji** | Versioned official catalog with license/provenance; native character palette also available |
| Converter | Length, mass, temperature, volume, speed and currency conversion | Physical units work locally; currency uses explicit Refresh and dated Frankfurter rates, with clear missing-rate errors and a dated rate label |
| System | Real CPU, memory, disk, network and battery statistics | Samples while visible; available hardware determines reported values |
| Quick Note | Auto-saved note with optional sync | Oversized/unreadable originals are preserved; explicit replacement keeps a backup |
| Now Playing | Music/Spotify or explicit System metadata, artwork, supported controls, local LRC and opt-in LRCLIB lyrics | Automation applies to Music/Spotify; System uses private MediaRemote and may be restricted; lookup sends track metadata only after opt-in plus a click |
| Shortcuts | List and run installed macOS Shortcuts | Explicit chosen shortcut; its own actions may request permissions |
| Quick Launcher | Pin/search/reorder apps, folders and Shortcuts; drop regular files onto an application pin to open them | File opening is explicit; synced apps use bundle IDs, folders need local resolution and Shortcuts must exist on each Mac |
| Workflows | Saved image resize → convert → compress → ZIP, or actual video compression with optional ZIP | Native drop or explicit run; preserves originals, validates smaller compressed outputs and rolls back failures; image/video stages cannot be mixed |
| Screenshot Shelf | ScreenCaptureKit area/window/display PNGs and short silent MOV recordings into File Shelf | Explicit Start and Screen Recording consent; recordings are 1–60 seconds; hiding/canceling ends capture and removes incomplete output |
| Color Picker | Screen sampling, HEX/RGB/HSL/SwiftUI/NSColor copy formats, history and named palettes | NSColorSampler starts only on Pick; saved palettes can sync; sampling history stays local |
| Volume & Brightness | Optional media-key interception with volume/mute/brightness HUD | Explicit Enable and Accessibility consent; unsupported devices/displays or keys pass through to macOS |
| Devices | Available Mac/HID battery information and explicit paired Bluetooth metadata | Missing battery values remain unavailable; background monitoring is optional |
| Status | Available microphone/input and camera activity, plus authorized Apple Focus shared state | Does not start capture; Focus requires explicit Connect and reports the public shared boolean, without identifying a mode |
| Network | Local interface details, traffic deltas and VPN/tunnel indicators | No external connectivity probe; a tunnel indicator is not a VPN security assessment |
| World Clock | Saved IANA zones, daylight-saving-aware conversion and actual Calendar meeting comparisons | Up to twelve zones; Calendar data uses existing authorized access; zone preferences can sync |
| GitHub Actions | Repository/workflow-run browsing through read-only GitHub.com APIs | Explicit Connect/Refresh; app-specific Keychain token, repository access, rate limits and bounded pagination |
| Focus Stats | Weekly completed focus-session chart and recent history | Local dated completions exclude pauses, canceled sessions and breaks; legacy counts do not invent history |
| Context Rules | Preview ordered rules for frontmost/running apps, meeting/music activity or Finder drag; select/show a matching visible tool | Service and starter rules start off; background observation is separate; rules never launch apps or run actions |
| Downloads | Observe partial-file growth and reveal an observed final file in a chosen Downloads/custom folder | Explicit Enable; total/progress/ETA stay unknown until you supply a total; Disable does not cancel browser downloads |
| Commands | Show command start/finish metadata from explicitly installed local helpers | Enable listener and install helpers explicitly; Python 3 required, no PATH edits; helper runs only your supplied command |
| Snippets | Searchable text/code folders, colors, copy, drag and explicit paste | Local by default; optional ordinary-text sync; 500 snippets, 32 KB each; credentials/codes should remain local |
| Translate | Typed/clipboard text, source/target language selection and copy using Apple's local models | **macOS 15+**; explicit Translate may prepare/download a supported language model; no cloud fallback |
| Dictation | On-device transcript and measured waveform, configurable hold shortcut, Quick Note append | Explicit Start/hold requests Speech and Microphone; shortcut, hold append and hidden recording each start off; unavailable on-device recognition fails |
| QR | Core Image QR PNG generation/drag/export and Vision scanning of a selected screen region | Encode locally; Scan explicitly requests the capture permission path; scanned links are not opened automatically |
| 2FA Codes | Read recent incoming Messages verification codes into a volatile 60-second view | Explicit Enable and user-granted Full Disk Access; optional hidden reading; no saved/synced codes or account-cache reads |
| Package Tracker | Read registered shipments from AfterShip and open an optional carrier page | Explicit key and Refresh; up to 20 local tracking references; shipments must already be registered with AfterShip |
| Habits | Daily checkoffs, streaks and a seven-week heatmap | Local dated history; up to 100 habits; optional sync shares the ordinary habit library |
| Travel Status | Read already-authorized Calendar departures and Aviationstack flight status | Calendar access is not requested here; explicit provider key/Refresh; live train status is unavailable |
| Sports Scores | Search/add football teams and read actual API-FOOTBALL live-game scores | Explicit provider key/search/refresh; optional five-minute background checks; no upcoming fixtures, completed results or match history |
| Search | Search configured local tools, notes, tasks, snippets, clipboard and shelf metadata | Existing enabled/visible sources only; no Spotlight, account-cache or filesystem indexing |
| Plugins | Explicitly enabled API-v1 manifest tools with text/list output and shell-button actions | Per-session enable and permission grants; shell builtins only, five-second/64 KB bounds; unavailable sandbox fails closed |
| File Actions | Original contextual image/PDF/media/archive/text transformations | Drag a local file toward the notch without keys; a real drop on a labeled action authorizes processing |

The table describes implemented behavior and setup. Native fixture tests, public HTTP probes, connected-account acceptance and physical hardware checks are recorded separately in [EVALUATION.md](EVALUATION.md).

## Using the tools

**Now Playing:** choose Music, Spotify or System and Connect explicitly. System uses MediaRemote; unavailable symbols, restricted access or missing metadata are reported, with Music/Spotify available as alternatives. Background monitoring is a separate opt-in. Local `.lrc` import works offline. For online lyrics, enable LRCLIB lookup, then click Lookup; the request sends title/artist/album/duration when available. Track changes cancel an existing lookup and do not issue a new request. Spotify artwork may load from the player's image URL after connection.

**Screenshot Shelf:** choose an area, window or display and start a screenshot or a short silent recording. Captures are validated and copied into managed File Shelf storage even when ordinary shelf Auto-save is off. Stop and Save finishes a recording; Cancel or hiding the capture tool stops it and cleans partial output. Sending a saved capture to a workflow requires a separate explicit action.

**Workflows:** create/select an image or video preset and drop files on its native target. Selecting Workflows before dragging reveals that target without a key press. Image presets offer resize, format, quality and one batch ZIP. Video presets use real H.264 MP4 compression, optionally followed by ZIP; failure to produce a smaller valid video rolls the run back. Outputs use unique names beside the source or in configured Downloads, preserving originals. Shortcuts' Run Workflow action waits for completion and returns durable output files; memory-backed input publishes to Downloads before its temporary input is removed.

**Ask Orbit:** explicitly add readable text/PDF/Markdown or screenshot files, choose an operation and Generate Preview. Summaries and CSV use at most the first 8,000 readable characters of each file; screenshot naming uses local OCR before the local model. Edit proposed names before Confirm. Naming produces uniquely named copies beside each source, preserving its bytes and original name. Undo removes only owned, unchanged outputs; edited or replaced copies remain. Generated CSV and summaries require review.

**Translate and Dictation:** choose languages and Translate explicitly; Apple's local language preparation may ask to download a model. Dictation requests Speech and Microphone only after Start or a held, enabled shortcut. The default hold is Control-Option-D; shortcut registration is off initially. Enable **Append completed hold dictation to Quick Note** to send the actual final transcript once on release. Start-button recordings use **Send to Quick Note**. Canceled/partial-only recognition is retained without appending, and failed saves retain the text and show the error. Background dictation has a separate default-off opt-in; otherwise hiding stops it, and a held shortcut refuses to start if the Dictation dashboard cannot be shown. Audio is not saved.

**QR and 2FA Codes:** type QR content to generate a real PNG, then drag or export it. Scan Screen Region starts the existing explicit screen-capture permission/selection path and recognizes codes locally with Vision. 2FA Codes reads only recent incoming plain-text Messages after you Enable and grant Full Disk Access in macOS. Codes expire after 60 seconds, remain volatile and are copied with a concealed marker. Hidden reading is separately enabled; rich-body-only messages are unsupported.

**Context Rules, Downloads and Commands:** configure and individually enable the desired rules while global observation is off, Preview Current Match, then Enable the service. Undo Last Selection restores the previous tool when available. Meeting context means a currently running authorized Calendar event with a join link; app rules detect app presence rather than proving a call. Finder drag context requires an activated notch file drag. Rules can select/open a visible tool, and do not run its operations. Downloads watches chosen-folder partial-file metadata after Enable; browser totals are unavailable, so progress and ETA require a positive user-supplied total and measured regular-file growth. Safari `.download` folders have unknown bytes, and paused observation cannot reconstruct missed completions. Commands requires Enable plus **Install User Helpers**. `orbit-notify` and `orbit-run` are installed only in this app's user Application Support folder, require Python 3 and do not change PATH. Use the copied shell/Xcode example with your own command. An Xcode Run Script tracks its wrapped command, not the whole build automatically; finish requires a matching observed start. The listener accepts bounded metadata through a private local UNIX socket and never executes an incoming message. Background observation/listening are separate opt-ins.

**Quick Launcher and Clipboard:** drop regular files on a pinned application to open them with that app; folder and Shortcut pins are not drop targets. Clipboard history is opt-in. Local OCR and explicit formatting/encoding/tracking-removal transforms do not upload input or overwrite it; copy the previewed result when ready.

**File Shelf and Orbit Inbox:** use named shelves and metadata-only moves, or Preview a capture/chosen-folder rule before explicitly enabling it. Folder rules scan only the chosen folder's top-level bounded regular files. Edits or changed synced rules disable their local execution until reviewed again. Legacy retention flags candidates for Preview Cleanup and confirmation. An expiry rule remains off until its exact definition is previewed and enabled; it then moves expired owned copies into private retained Undo trash, including while hidden. Undo disables matching local expiry rules and requires a fresh preview before re-enabling. IO failures pause automatic retries across relaunch until explicit Retry. Undo survives relaunch; originals and referenced files are never deleted, and trash is not automatically purged. Choose an Orbit Inbox folder, Enable it and explicitly send a shelf file or typed note. Open that folder in iPhone Files if your folder provider supports it. The app confirms this Mac's local write, not iCloud delivery or Handoff.

**Snippets, Habits and Search:** organize ordinary text/code in local snippet folders, copy or drag a snippet, and record real daily habit checkoffs. Snippet syncing is separately opt-in; keep secrets and verification codes local. Search queries configured, already-enabled local stores, with arrow-key selection and Return to activate a result. It does not request integration access or index the system.

**Package Tracker, Travel Status and Sports Scores:** save your own provider key, then Search or Refresh explicitly. AfterShip reads shipments already registered in your account. Travel can read already-authorized Calendar events, then query Aviationstack flights; trains have calendar countdowns and optional operator links, without a live train adapter. Sports supports API-FOOTBALL team search and live games only; upcoming fixtures, completed results and match history are unavailable. Provider plans, rate limits and optional/missing fields are shown honestly; optional background weather/sports polling is separately enabled.

**Plugins:** choose a folder containing an API-v1 `manifest.json`, review its declared permissions and explicitly Enable plugins for the session. Bundled samples demonstrate the format. Buttons run bounded shell-builtin scripts only; network, external executables and undeclared filesystem access are denied. Clipboard and chosen read-only folder access require explicit grants. If the required macOS sandbox runner is unavailable, execution remains disabled.

**Planning and services:** currency requires an explicit refresh and displays the provider's actual rate date. World Clock converts the same instant across saved zones and can use authorized Calendar meetings. Focus Stats charts recorded completions from Timers. Start Focus starts the app's local timer; Status separately reads the authorized Apple Focus shared boolean. GitHub Actions reads repositories and runs only after Connect/Refresh with your own token.

## Settings, keyboard and sync

The compact notch prioritizes processing, HUD, dictation, verification codes, meetings, travel, focus, commands, downloads, music, packages, sports, weather, devices and status. Secondary indicators retain concurrent activities. **Settings → Live Priority** lets you reorder these kinds. **Appearance** provides System/Light/Dark, accent color and optional successful-drop/workflow sound; sound starts off.

Hover expansion does not activate the app or take keyboard focus. Manual pinning keeps the dashboard open. On notchless displays, an optional menu-bar left click opens the dashboard; right click opens its menu.

Timers can preview and explicitly enable hiding selected running apps during active focus. Pause, completion, cancellation, Disable or Restore Apps Now unhides only app instances this feature hid, checked by process identity and launch date. It never launches or quits apps.

Settings provides per-display enabled/width choices, All Spaces/Current Space placement and opt-in fullscreen hiding. Fullscreen detection uses separately granted Accessibility access and keeps unknown windows/displays visible. Display geometry, permission state and shortcut configuration remain local.

**⌘⌃N** toggles the dashboard. Tab moves through native controls; arrow keys navigate the tab strip; Control-Tab/Control-Shift-Tab switch tools; Escape collapses the dashboard. VoiceOver labels and Reduce Motion support are implemented, with interactive assistive-technology acceptance still required.

**Settings → Sync** selects the same iCloud Drive, Dropbox or network folder on each Mac and enables sharing. Sync starts off. It shares Quick Note, To-Dos, logical launcher pins, workflow presets, saved palettes, tool order/visibility, hover/click preferences, appearance, live priorities and World Clock zones. This expansion adds optional ordinary-text snippets, habits and shelf/rule definitions. Clipboard, shelf file bytes, credentials, verification codes, pick history, meeting data, absolute paths, bookmarks, selected shelf, rule enablement and Orbit Inbox configuration stay local.

Each Mac writes its own coordinated versioned snapshot. Task deletions retain tombstones. Different library categories merge independently; concurrent changes within a launcher/workflow/palette/snippet/habit/shelf-definition category retain whole variants until you choose, with a private backup before resolution. Editors and unsaved notes are protected before incoming apply. Apps resolve by bundle ID; synced folder pins require an explicit local folder choice. **All participating Macs need the expanded schema-3 build:** it reads schema 1/2 snapshots and writes schema 3. Earlier schema-1/2 packages cannot apply that new format; earlier 0.3 packages are not schema-3 compatible. Folder JSON is readable to whoever can access the folder; a successful write confirms this Mac's local write, while cross-Mac delivery belongs to your folder provider.

**Settings → Updates** provides launch-at-login, automatic checks every six hours, checksum-verified downloads and trusted installation. All update automation starts off. Ad hoc builds support verified downloads and manual installation; automatic replacement requires a Developer ID signed running app and a notarized update from the same team. The public [stable feed](https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/stable.json) is published only after a successful macOS build.

## Shortcuts actions

The installed app exposes **Start Focus**, **Add File to Shelf**, **Run Workflow**, **Toggle Dashboard** and **Capture Screenshot** through AppIntents. Actions bring the app to the foreground. File inputs must be bounded regular files (at most 100 MB). Run Workflow selects a real saved preset, forwards errors/cancellation and returns output files for the next action. Capture Screenshot requests Screen Recording access only when explicitly run. Discovery, user permissions and actual Shortcuts execution still require acceptance on the installed Mac.

## Data and privacy

Notes, tasks, snippets, habits, clipboard history, shelf definitions/copies, scripts, imported usage, focus completions and capture records use this app's local storage. OCR, text transforms, QR, supported translation, dictation and Foundation Models run locally. Visible tools stop sampling/capture when hidden unless their specific background opt-in permits it. Managed-copy cleanup and generated-name Undo preserve originals; verification codes are volatile and excluded from history/sync.

Weather, FX/currency, stocks, GitHub Actions, merchant integrations, AfterShip, Aviationstack, API-FOOTBALL and LRCLIB contact their providers on explicit requests or their separately enabled background schedule. The new provider adapters use fixed approved HTTPS origins and app-specific Keychain accounts `aftership`, `aviationstack` and `api-sports-football`; they reject redirects and bound response size/pages. Spotify artwork uses the connected player's image URL. Credentials stay in this app's macOS Keychain namespace; use read-only provider permissions where supported. There is no telemetry or remote AI fallback. AI Usage does not inspect sign-in caches or extract tokens: an explicit live Codex read delegates authentication to your chosen, already signed-in CLI and reads only documented quota windows, without model/thread/turn/tool calls.

## Build

On a Mac with **Xcode 26 or later**, CMake, Python 3 and Git:

```bash
bash NotchOrbitPlus/Scripts/build.sh
open NotchOrbitPlus/build/DerivedData/Build/Products/Release/NotchOrbitPlus.app
```

The app keeps a macOS 14 minimum while weak-linking Translation for macOS 15+ and FoundationModels for eligible macOS 26 systems. Building with an older SDK is rejected so the AI feature is not silently omitted. The script runs portable/native tests, builds both architectures, verifies signing and startup, and writes `NotchOrbitPlus/dist/NotchOrbitPlus.app.zip` and its SHA-256 checksum. It uses an ad hoc signature when no Developer ID identity is configured; notarization is never inferred from a successful development build.

### Developer ID and notarization

The pipeline supports hardened runtime signing, Apple notarization, stapling and Gatekeeper assessment. Actual notarization needs your Apple Developer certificate and App Store Connect notarization credentials. Configure values securely in **GitHub repository Settings → Secrets and variables → Actions**; do not place them in source or chat.

| GitHub Actions secret | Purpose |
| --- | --- |
| `NOTCHORBITPLUS_DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as `.p12` |
| `NOTCHORBITPLUS_DEVELOPER_ID_P12_PASSWORD` | Password protecting that export |
| `NOTCHORBITPLUS_SIGNING_IDENTITY` | Optional certificate name or hash; a sole Developer ID identity is detected automatically |
| `NOTCHORBITPLUS_NOTARY_KEY_BASE64` | Base64-encoded notarization `.p8` API key |
| `NOTCHORBITPLUS_NOTARY_KEY_ID` | That key's identifier |
| `NOTCHORBITPLUS_NOTARY_ISSUER_ID` | Its issuer identifier |

After configuring credentials, update the version/build numbers in `Resources/Info.plist`, commit that change, and run the NotchOrbitPlus workflow on the current source branch. A new version lets installed apps detect the signed release and keeps existing package URLs immutable. The temporary signing keychain is removed after the job. Local Mac builds can use an existing Keychain identity through `NOTCHORBITPLUS_SIGNING_IDENTITY` and an existing `notarytool` profile through `NOTCHORBITPLUS_NOTARY_PROFILE`.

The published feed records version, source commit, archive size/SHA-256 and actual signing/notarization results. The updater rejects redirects and incorrect size/checksums. Installation verifies the running application's Apple trust, candidate bundle/version, all architecture signatures and the same signing team; automatic installation additionally requires successful notarized-app assessment. It keeps a recovery copy when replacing an installed app. Ad hoc builds require manual installation.

Portable tests on the cloud Linux environment:

```bash
bash NotchOrbitPlus/Scripts/cloud-core-tests.sh
```

The independent workflow `.github/workflows/notchorbitplus.yml` uses a real macOS 26/Xcode 26 runner and publishes status, logs, previews and successful app packages on `codex/notch-plus-builds/run-<id>-<attempt>` branches for Git-only retrieval.

## Native previews

The preserved verified 31-tool build generated captures of actual native views, including its 31 dashboard modules. New 45-tool captures and test totals are pending the expanded build and are not represented by these older images. Additional images use clearly labeled synthetic fixtures for dated rates, session history, media state, HUD and priorities. The completed 0.3 run generated **54 native PNGs**; the files below are copied unchanged from that artifact. Fixtures are identified by their output names and documentation captions. Rendering does not establish physical-notch placement, hardware permissions or connected accounts.

![Screenshot Shelf with explicit capture controls](docs/NotchOrbitPlus-Dashboard-capture.png)

![Color Picker with native sampling and saved palettes](docs/NotchOrbitPlus-ColorPicker.png)

![World Clock showing labeled saved-zone fixtures](docs/NotchOrbitPlus-WorldClock-fixture-saved-zones.png)

![Currency conversion using labeled dated-rate fixtures](docs/NotchOrbitPlus-Currency-fixture-dated-rates.png)

![Focus Stats using labeled completed-session fixtures](docs/NotchOrbitPlus-FocusStats-fixture-completed-history.png)

![Dark appearance settings fixture](docs/NotchOrbitPlus-Appearance-fixture-dark.png)

![Per-display and Spaces settings fixture](docs/NotchOrbitPlus-DashboardSettings-fixture-display-spaces.png)

![Custom live-priority settings fixture](docs/NotchOrbitPlus-Priority-fixture-custom.png)

![Saved workflow with native drop target](docs/NotchOrbitPlus-Dashboard-workflows.png)

![Quick Launcher with local target controls](docs/NotchOrbitPlus-Dashboard-launcher.png)

![First-run setup in its native window](docs/NotchOrbitPlus-Onboarding.png)

![Original native file-action semicircle](docs/NotchOrbitPlus-Convert.png)
