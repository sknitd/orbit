# CornerOrbit

A native menu bar app for **macOS 14 and later**, with an independent action for every gesture at every screen corner. Version **0.2.0 adds [50 features](FEATURES-0.2.0.md)**: profiles, more gestures, window controls, Mac actions, favorites and local clipboard tools. The universal app supports Apple silicon and Intel Macs. All changes stay inside `CornerOrbit/`; the other Orbit apps and repository workflows are unchanged.

<!-- RELEASE_EVIDENCE -->
The v0.2.0 package and executed validation evidence are being prepared. Build instructions are below.
<!-- /RELEASE_EVIDENCE -->

![Native CornerOrbit settings](docs/CornerOrbit-Settings-four-corners-fixture.png)

The screenshot uses a labeled fixture. Production starts with all actions unassigned and monitoring off.

## Install and use

Extract `CornerOrbit.app` from the ZIP, move it to Applications and open it. This build is ad hoc signed, **not Developer ID signed or notarized**. macOS may require **System Settings → Privacy & Security → Open Anyway** for the downloaded app.

1. Select a corner and edit its actions. There are **13 gesture bindings per corner, 52 total**: left single/double/triple click, drag in/out, right single/double/triple click, middle click, hover, press-and-hold, scroll up/down. Search the action catalog to find an action; saving never runs it. Undo/Redo restores binding edits without changing permission choices.
2. Click **Enable gestures**. If requested, allow CornerOrbit in **Privacy & Security → Input Monitoring**, then enable again. Restart if macOS requires it. The menu bar provides pause/resume and Settings.
3. Use **Gestures & Practice** to test recognition without executing actions. Customize each corner's area/modifiers and hover/hold delays. Behavior contains shared timing, cooldown, hints and display selection.
4. In **Profiles & Rules**, save named configurations, duplicate them, review/import JSON or export them. App rules and exclusions are optional. Choose 5/15/60-minute pauses or opt into Launch at Login. Applying a profile preserves current monitoring and Automation choices.
5. Enable **Allow document and tab Automation** in Behavior before running browser-tab, Finder-window or blank document actions. macOS asks for the specific target app only when an action runs. Window controls request **Accessibility** when explicitly run. Missing apps and denied access show errors.
6. Connect local Chrome history in **Websites**, manage **Favorites & Groups**, or open **Clipboard** for explicit Read → Preview → Apply → Undo. No page reads the clipboard merely by opening.

Single/double clicks wait for the multi-click interval; a triple click runs once. Drags require a mouse drag and sufficient movement, then fire on release; a corner-to-corner drag favors the starting corner's Drag Out. Hover fires once per entry; press-and-hold suppresses a subsequent click/drag from that press. Events are observed, not consumed: underlying apps and macOS Hot Corners may also respond. Use modifiers or disable conflicting Hot Corners.

## Actions and tools

The catalog has **60 entries including None**. Related formatting modes count as one feature in the [numbered 50-feature list](FEATURES-0.2.0.md).

| Group | Available actions or controls |
| --- | --- |
| Existing browser actions | Chrome new tab, local Chrome history and recent-websites dropdowns, WhatsApp Web, custom HTTP(S) website. |
| More browser actions | Chrome private window; explicitly search clipboard text with **Google in Chrome**; Safari new tab. |
| Documents | Separate blank Word, Excel, PowerPoint, TextEdit, Pages, Numbers and Keynote documents; new TextEdit draft from clipboard. Installed apps are required. |
| Apps and files | ChatGPT, Claude, Spotify, Activity Monitor, Finder, custom installed app, Downloads, Applications, System Settings; new Finder window; saved file/folder. |
| Windows | Left/right halves, maximize usable area, center, next display, restore previous frame, minimize and fullscreen toggle. Hide other regular apps and restore only apps CornerOrbit hid. |
| Mac tools | Run a named Shortcut, explicitly refresh the Shortcut-name picker, open Screenshot toolbar, start Screen Saver. Screen Saver does not promise to lock the Mac. |
| Links | Searchable favorites, editable ordering, and named groups of up to 10 websites opened in Chrome. |
| Clipboard | Plain text, JSON prettify/minify, URL component encode/decode, Base64 text, case conversion, tracking-parameter removal, line trimming/deduplication, guarded one-step Undo. |
| Profiles | Create/rename/delete/duplicate, JSON review/import/export, ordered frontmost-app rules, app exclusions, timed pause, optional login launch. |
| Gesture configuration | 52 bindings, per-corner sizes/modifiers, dwell/hold timing, practice mode, action search and binding Undo/Redo. |

Fixed document/tab scripts have timeouts; user strings are never executable AppleScript or shell source. Shortcuts use a bounded, cancellable `/usr/bin/shortcuts` process with separate arguments. A chosen Shortcut can perform its own effects; canceling cannot undo effects it has already performed. TextEdit clipboard drafts are new private files in this app's `Drafts/` directory. Window restore and app-hide ownership are session-only and bounded; supported controls vary by target app.

## Profiles, links and clipboard privacy

Profiles contain bindings and gesture settings, excluding monitoring/Automation consent. Import shows every configured action and parameter, adds reviewed snapshots, and never activates one or enables app rules. App switching uses workspace activation notifications only after the relevant option is enabled. A failed profile application pauses recognition and displays the error. Timed resume cannot override disabled monitoring, an excluded app or missing access.

Favorites and groups are local and saved atomically. Groups open at most 10 validated websites; cancellation stops remaining opens, and a partial failure reports how many opened. Links already opened cannot be undone. Chrome history and optional recents are separate from favorites.

Clipboard data stays in memory; there is no clipboard watcher or disk history. Transform before/after text can be previewed. Undo preserves original item types and bytes, with a 2 MiB backup limit, and refuses to overwrite a clipboard that has changed. Oversized or unsupported backups produce errors before a transform writes. Google search sends the explicitly chosen clipboard text to Google only when that action runs.

## Chrome history and recent websites

In **Websites**, explicitly choose a Chrome profile folder or its `History` file, commonly `~/Library/Application Support/Google/Chrome/Default/History`. Connecting reads the chosen database; later refreshes are explicit. Dropdowns use loaded entries. Arrow keys select and Return opens in Chrome; the dropdown anchors to the menu bar icon.

SQLite uses a bounded read-only query and timeout. Live WAL access can create/update SQLite's transient `-shm` index/lock sidecar; CornerOrbit does not edit records, checkpoint, delete or copy browser history. Failures remain visible and retain previous loaded entries/timestamp. Up to 100 Chrome entries remain in memory until disconnect/quit; only the chosen connection bookmark is stored. macOS controls file access.

**Remember websites opened through CornerOrbit** is separately opt-in, keeps up to 200 successful explicit opens locally, and does not observe browsing. Turning it off clears its links. There is no account, telemetry, sync or cloud AI. Website/search actions open the named website only on an explicit action; no background network fetch is added.

## Storage and compatibility

The bundle and storage namespace is `com.sknitd.CornerOrbit`, under `~/Library/Application Support/`. Settings, profile and link JSON are validated, bounded and privately/atomically written; corrupt files are preserved for explicit recovery. Existing v0.1 settings migrate with original bindings intact and new gestures unassigned. Profile exports can include configured paths and URLs: review them before sharing.

Previously enabled monitoring resumes only if already authorized. Startup never requests access. Disabled monitoring has no event tap or sampling timer; click/dwell timers are one-shot. Settings changes, pauses, display/session transitions and practice changes cancel pending recognition. App-context observation uses notifications and stops when both rules and exclusions are unused. No other Orbit app's files or settings are read or modified.

## Build and validation

```sh
# From the repository root; Swift 6, macOS or Linux:
bash CornerOrbit/Scripts/cloud-core-tests.sh

# On a Mac with Xcode 16+:
cd CornerOrbit
python3 Scripts/generate-project.py --check
bash Scripts/build.sh
```

The Mac script runs portable and hosted native tests, captures native fixture views, builds arm64 and x86_64 with a macOS 14 minimum, checks an ad hoc signature, measures idle CPU/RSS, and produces `dist/CornerOrbit.app.zip` and its SHA-256 checksum. See [EVALUATION.md](EVALUATION.md), [implemented-features.md](implemented-features.md) and [known-limitations.md](known-limitations.md).

The workflow lives at [`.github/workflows/build.yml`](.github/workflows/build.yml). CI uses the isolated `codex/cornerorbit-build` subtree branch so existing root workflows stay unchanged. Each run preserves exact source identifiers, logs, previews and any successful package in an immutable result commit.
