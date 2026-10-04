# Implemented features

This root catalog describes **OrbitDrop**. The separate NotchOrbitPlus 0.3.0 dashboard has its own [implemented features](NotchOrbitPlus/implemented-features.md), [limitations](NotchOrbitPlus/known-limitations.md) and [build evidence](NotchOrbitPlus/EVALUATION.md), including system media, capture, HUD, devices, planning tools, sync and AppIntents.

This describes implemented source behavior, not a claim that all native behavior has passed interactive macOS acceptance. See the recorded automated results and [MANUAL-ACCEPTANCE.md](MANUAL-ACCEPTANCE.md).

## Application and interaction

- Native macOS 14+ menu bar utility using Swift 6, AppKit, and SwiftUI; no main document window.
- Public listen-only drag observation with configurable Shift or Shift + Option trigger, pause/resume, Escape cancellation, and explicit Input Monitoring controls/status.
- A real AppKit file-drag destination. Preview URLs must match the actual drop payload; the action is rechecked against freshly inspected files before execution.
- Fixed inner category positions and one outer options ring. Center, gap, and outside drops cancel. There are no automatic gesture actions or keyboard execution.
- Shift + Option opens the available Privacy category; its compact still-image summary reports standard metadata-category presence without exposing values. It labels unsupported metadata inspection rather than claiming the file is clean.
- Native material, SF Symbols, light/dark styling, selection emphasis, haptic feedback where available, Reduce Motion/Increase Contrast handling, and VoiceOver labels.
- Screen-containing cursor selection, `visibleFrame` clamping, Retina point coordinates, and public Spaces/fullscreen collection behavior. Interactive multi-display/Spaces behavior still needs a Mac check.
- Choose Files fallback, which presents the same wheel and still requires an actual drag of those selected files.
- Results/progress window, operation cancellation, Finder reveal, file-URL clipboard copy, and dragging the first output to another application.
- Persistent settings for image quality, output destination, trigger, optional completion sound, and optional launch at login through `SMAppService`.

## Action catalog

There are 23 action identifiers:

| Area | Concrete actions and behavior |
| --- | --- |
| Images, 8 | JPEG, PNG, HEIC, WebP; Compress Image; Resize to 1600 px; Remove Metadata; Remove GPS. Still-image decoding applies orientation. Resize never upscales. JPEG flattens transparency on white. Compression publishes only a smaller result. WebP uses bundled static libwebp. |
| Documents, 5 | Images to PDF; Merge PDFs; Split PDF; PDF to PNG; Extract Text. Merge needs at least two PDFs. PDF rendering uses bounded Core Graphics rasterization. Text extraction uses embedded PDF text when available and local Vision OCR otherwise. |
| Media, 4 | Convert to MP4; Compress Video; Extract Audio; Convert to M4A. AVFoundation selects compatible presets and validates required tracks, duration, and expected video codec. Compression publishes only a smaller result. |
| Archives, 2 | Create ZIP; Extract ZIP. Create ZIP supports files/folders, one archive per selected item. Extract ZIP accepts the strictly validated classic ZIP flavor. |
| Files/text, 4 | SHA-256 Checksum; Duplicate; Format JSON; Minify JSON. Checksum reads in blocks; JSON processing is limited to 50 MB and validates its output. |

The resolver offers only common file operations for mixed types. Folder selections are limited to ZIP creation. Actual encoders, valid tracks, file contents, and safety limits are checked by the engines, so some candidate actions can return an explanatory unsupported-input error.

## Output and privacy behavior

- Originals are retained; output collisions use numbered names. Outputs go beside sources or to Downloads.
- Private staging, free-space checks, validation before exclusive rename, and operation-scoped cleanup on failure/cancellation.
- ZIP structural checks, path collision/traversal rejection, bounded expansion, read-only source snapshot, and monitoring during extraction.
- Memory-only result records. Default: latest result for Undo. Optional: at most 20 records, age-filtered to 24 hours on every read and insertion without idle polling. The UI displays the latest result.
- Undo of only the latest generated regular files after identity/size/modification-time checks. Extracted folders and changed/unverifiable files are refused.
- No application runtime uploads, telemetry, AI processing, or persistent document-content index.

## Build support

The macOS script generates the project, prepares a pinned WebP dependency, builds a universal `OrbitDrop.app`, creates `.icns` sizes from the user-logo adaptation, includes dependency notices, applies/verifies an ad hoc signature, and packages a ZIP/checksum. GitHub Actions runs that script and preserves build results in artifacts and workflow-owned Git branches. The portable core can be tested separately on Linux.
