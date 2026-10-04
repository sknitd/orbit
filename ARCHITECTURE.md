# CornerOrbit architecture

CornerOrbit is an independent macOS 14+ menu bar application. Source, tests, documentation, build scripts and CI configuration live in this directory. Its identity and storage namespace is `com.sknitd.CornerOrbit`.

`Sources/CornerCore` contains portable settings, profile import/rule validation, clipboard transforms, link models, window geometry, URL/history normalization and gesture recognition. `Sources/CornerOrbit` provides mouse observation, native actions, profiles/context/login services, local tools, Chrome history, SwiftUI settings and AppKit menus. Tests inject providers or use private local fixtures without personal accounts or permission prompts.

Each corner has 13 bindings: left/right single/double/triple clicks, middle click, drag in/out, hover, press-and-hold and vertical scroll in either direction. Old settings retain their five original bindings; new gestures default to None. The Core recognizer resolves button families, timing, modifiers, corner overrides and cooldown. Native adapters provide display snapshots and one-shot deadlines, invalidate deferred deliveries on lifecycle/settings changes, and route practice results separately from actions. Mouse events pass through to macOS; no keyboard capture is installed.

`CornerAppStore` serializes explicit actions and cancels stale work by task identity/generation. Permission preferences are separate from portable profiles. Binding undo records only a bounded set of action edits, and profile application preserves current permission choices. Frontmost-app notification observation runs only when app rules or exclusions are configured. Timed pause, exclusions and failed profile applications prevent automatic monitoring resume from overriding user choices.

Window actions use injected providers. The native provider confines AX objects to an actor, bounds AX messaging time, retains limited frame history, verifies resulting frames and attempts rollback on failure. Hide/restore ownership is session-only and identified by PID plus launch date. Mac scripts are fixed; Shortcut names are passed as Process arguments, never shell code. TextEdit clipboard drafts use exclusive private files.

Clipboard reading is explicit; transformation logic is portable. Native publication preserves bounded original item types in memory and guards undo using both change count and content. Favorites/groups and profiles are validated before private atomic local publication. Profile JSON import previews all action parameters and never enables consent, activates profiles or imports context rules.

Chrome history uses explicit local file selection and bounded SQLite read-only queries, including live WAL coordination. Recent websites are separately opt-in and record only successful explicit opens. The settings UI never executes an action merely by selecting, importing or saving its binding.

The self-contained `.github/workflows/build.yml` executes when this directory is the root of `codex/cornerorbit-build`. This provides a genuine universal macOS build without changing another app or an enclosing repository workflow. Result commits preserve immutable source identity, native captures and package evidence.
