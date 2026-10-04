# Implemented features

CornerOrbit 0.2.0 adds the [50 numbered features](FEATURES-0.2.0.md) to the independent original app. Executed checks and physical-Mac limits are recorded separately in [EVALUATION.md](EVALUATION.md).

| Additions | Implementation | Verification ownership |
| --- | --- | --- |
| 1–8 Profiles and controls | `CornerCore/CornerProfiles.swift`, native `Profiles/`, `CornerProfilesView` and app-store integration. | Core profile/import/rule cases; injected context, pause and login providers; private persistence fixtures. |
| 9–10 Search and binding undo | `CornerBindingEditorView`, bounded action-only undo/redo in `CornerAppStore`. | Independent app-store fixtures and native editor capture. |
| 11–18 Gestures and practice | Core settings/recognizer, native mouse adapter/monitor, `CornerGestureOptionsView`. | Original gesture regressions plus expanded pointer/timing/lifecycle/practice fixtures. |
| 19–28 Window controls | Core window layout and native `CornerWindowActions`. | Portable display math and injected AX/window/app-provider tests. |
| 29–40 Mac actions | Core action catalog/validation, native action runner, fixed scripts, private drafts and Shortcut process adapter. | Validated parameter, routing, permission, filesystem, timeout/cancellation fixtures. |
| 41–42 Favorites and groups | Core links and native `Tools/Links`, settings editors and menu dropdown. | Model validation, private local storage and routing fixtures. |
| 43–50 Clipboard | Core transforms and native `Tools/Clipboard`, explicit workspace view. | Parsing/encoding/number-preservation cases and private pasteboard fixtures including guarded undo. |

The original actions remain available: Chrome new tab/history/recent websites, separate Office/TextEdit documents, WhatsApp Web, desktop ChatGPT/Claude/Spotify, Activity Monitor, Finder, custom app/website, Downloads, Applications and System Settings. The catalog now has 60 entries including None and each corner has 13 bindings (52 total).

Monitoring, Automation, app rules, recent websites and login launch remain opt-in. Accessibility is requested only by explicitly run window controls. Profiles exclude permission choices. New settings preserve v0.1 data and malformed files remain recoverable. No real browsing data, credentials, clipboard text or target-app permissions are required by automated tests.
