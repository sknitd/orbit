# CornerOrbit

CornerOrbit is an independent macOS 14+ menu bar application. All source, tests, documentation, build scripts and CI configuration live in this directory. It uses `com.sknitd.CornerOrbit` for its application identity and local storage.

`Sources/CornerCore` contains portable configuration, geometry, URL/history normalization and gesture recognition. `Sources/CornerOrbit` contains native mouse observation, app/document actions, read-only Chrome history, settings and menu UI. Tests never require real browser history, installed Office apps or permission prompts.

Each corner has five independent bindings: single click, double click, triple click, drag into the corner and drag out of the corner. Single and double clicks wait for the configured multi-click interval. Recognition occurs on mouse release. A drag starting in a corner takes precedence over a drag ending in another corner so one release cannot run two actions.

Gesture monitoring starts disabled. Input Monitoring and Automation are requested only through explicit user choices. Captured events are mouse events only and pass through to macOS. Chrome history requires an explicit local file/profile selection and is read without modifying the database. Recent websites are only the URLs successfully opened through CornerOrbit after the user enables that local list.

The self-contained `.github/workflows/build.yml` runs when this directory is published as the root of the separate `codex/cornerorbit-build` branch. This permits a genuine universal macOS build without changing another app or a workflow in the enclosing checkout.
