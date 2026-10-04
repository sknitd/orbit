# Known limitations

The limitations below describe **OrbitDrop**. The separate NotchOrbitPlus 0.3.0 dashboard records its own [limitations](NotchOrbitPlus/known-limitations.md) and [executed evaluation](NotchOrbitPlus/EVALUATION.md), including private MediaRemote restrictions, hardware consent, optional sync and signing/update requirements.

The implementation covers the actions and interaction listed in [implemented-features.md](implemented-features.md). The supplied product specification describes a much larger roadmap. Source implementation, automated native tests, interactive validation, and production distribution are distinct milestones.

## Native validation and distribution

The Linux development machine can test the portable core but cannot compile/link macOS frameworks or run Finder. A real `.app` requires the macOS build script or the macOS CI runner. Native test results must be read from the relevant build log; the interactive checklist remains manual even after CI succeeds. Idle CPU, memory/latency targets, 60/120 Hz animation performance, TCC prompts, and long-running stability have not been established by Linux tests.

Developer builds are ad hoc signed. Developer ID signing, notarization, automatic updates, App Store sandboxing, and release entitlement review are not implemented. Launch-at-login registration may require macOS approval and should be checked with the installed app.

## Interaction

- Public macOS APIs do not expose a general system-wide `NSDraggingSession` observer. The monitor conservatively combines a physical drag with a freshly written file drag pasteboard; the destination separately proves an actual valid drop.
- Global activation requires Input Monitoring and can be unavailable under secure input or other system restrictions. Starting/unpausing midway through a drag does not activate. Some applications reuse a pasteboard or expose only file promises and therefore cannot activate this wheel.
- Finder/Desktop file-URL drags are the primary workflow. Mail promises, browser image/text drags, remote URLs, and arbitrary application drag formats are not supported.
- Choose Files still requires dragging those same files into the wheel. There is no keyboard-only execution path, Finder-selection hotkey, action search, or service/Quick Action integration. Keyboard focus during an external drag is controlled by macOS.
- Shift + Option opens Privacy when available but does not unlock additional actions. The second ring offers concrete formats/options, with a maximum of two rings; there is no advanced or AI wheel.
- The panel clamps on the display containing the activation cursor. It does not dynamically relocate between displays during an ongoing drag. Spaces, fullscreen apps, Stage Manager, VoiceOver, and mixed-DPI layouts require interactive acceptance.

## File and format constraints

- Transformations do not overwrite originals. Symlink and special-file inputs are rejected. Folder processing is ZIP creation only, without a recursive conversion mode.
- Image actions operate on still images. Animated/multipage images are rejected rather than silently flattened. Conversion and metadata actions can reencode lossy formats. JPEG removes alpha by flattening onto white; WebP output is lossy and does not preserve arbitrary metadata/profile containers. Selective GPS removal is unavailable for WebP.
- Image files are limited to 512 MiB. ImageIO full-size decoding is capped at 40 megapixels; downsampling paths permit bounded larger input dimensions. WebP has its own decode bounds. Native HEIC availability depends on the Mac's encoder support.
- Remove Metadata/GPS are image property transformations, not content redaction or forensic sanitization. The compact privacy summary detects only standard GPS and selected EXIF/TIFF details in supported still images; WebP/multiframe metadata is marked uninspected. No full privacy inspector or document metadata audit is implemented.
- PDFs are limited to 512 MiB and 2,000 pages each; merge has a 1 GiB source-total limit and 2,000-page output limit. Images-to-PDF is limited to 2,000 images. PDF PNG rendering targets 144 dpi with 4,096-pixel-edge and 16-megapixel bounds. Locked PDFs must be unlocked elsewhere.
- PDF compression, encryption, password management, redaction, annotations, arbitrary reorder, page-range options, and searchable OCR-PDF output are not implemented. OCR produces plain text; recognition can be inaccurate.
- Media uses AVFoundation-compatible source formats and native presets. Unsupported codecs/containers, protected media, invalid duration, or missing required tracks are rejected. No FFmpeg backend, codec/bitrate picker, trimming, cropping, GIF creation, joining, normalization, transcription, or lossless media optimization is implemented.
- Extraction accepts only a strict classic ZIP flavor. ZIP64, encryption, split archives, ambiguous encoding, unsupported extras, links, path conflicts, more than 10,000 entries, more than 2 GiB expansion, entries over 512 MiB, and ratios over 200:1 are rejected. RAR, 7z, tar, and gzip extraction are not implemented. ZIP creation processes each selected item into a separate archive.
- JSON formatting is capped at 50 MB, sorts object keys, and can change formatting/numeric representation. It is not a lossless source-preserving editor.
- Free-space checks are estimates; another process can consume space or modify sources during an operation. Crash recovery and cleanup of abandoned staging directories are not implemented.

## Results and Undo

History is memory only. The default retains the latest result; optional history is capped at 20 and filters records older than 24 hours on every read and insertion. There is no persistent history browser, thumbnail store, searchable activity log, or timed background expiration. Expired records can remain in backing memory until insertion, clearing, or quitting. The results panel displays the latest entry and offers a drag of its first output.

Undo is available only for the latest operation and only for generated regular files with usable identity, size, and modification-time metadata. Extracted folders are refused because nested contents may have changed. Edits preserving all checked metadata cannot be detected; Undo is not content-hash based. Trash operations are not an all-or-nothing filesystem transaction and can partly succeed before an error.

## Roadmap features not implemented

- Learned rankings, gesture memory, learned/pinned custom actions, usage profiles, personalized suggestions, and action recommendations.
- Frontmost-app/destination context, intent prediction, dwell estimates, size/quality comparisons, rich previews, and an expandable privacy inspector.
- Recipes, chains of actions, reusable presets, preset sharing, watched folders, automation rules, and folder-content conversion.
- Local/cloud AI wheels, model installation, semantic rename, summarization, translation, transcription, and generative editing.
- Clipboard image transforms, optimized temporary clipboard files, cleanup policies for them, drag-payload replacement, and returning a transformed payload into the original drag session.
- Image crop/rotate/redact/color-space tools, contact sheets, GIF/animation tools, advanced PDF editing, broader document conversions, and advanced audio/video editing beyond the catalog.
- Global shortcut execution, Finder selection integration, action search, custom trigger bindings beyond the exposed Shift/Shift+Option preference, and custom wheel layout controls.
- Persistent result history, automatic updates, an installer/DMG, telemetry, performance instrumentation, localization, and the full requested settings/extension ecosystem.

These absent features do not have placeholder controls that claim to execute them.
