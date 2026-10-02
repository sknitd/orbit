# Interactive macOS acceptance

Run this checklist with the application built from the source commit under review. Record the commit, macOS/Xcode versions, Mac architecture, display arrangement, Input Monitoring state, and a pass/fail result with evidence. CI and Linux core tests do not complete these checks.

Use disposable copies of test files and a writable output directory. Keep source checksums so input preservation can be checked. Do not record confidential document contents or secret values in screenshots/logs.

| Check | Procedure | Expected result |
| --- | --- | --- |
| Bundle launch | Build with `bash Scripts/build.sh`, verify the ZIP checksum, inspect `lipo -archs`, open `OrbitDrop.app`. | Application launches as a menu bar utility; universal executable contains `arm64` and `x86_64`; icon is the Orbit logo adaptation. |
| Permission denied | Launch without Input Monitoring. Open How to Use/Settings. | Clear permission/status message; no false claim that observation is active; Choose Files remains available. |
| Permission grant | Use the permission control, enable OrbitDrop in macOS Input Monitoring, quit/reopen if required. | Monitoring status reflects success or an explicit event-tap failure. No Accessibility-control prompt is required. |
| Finder activation | Start dragging a JPEG, then hold Shift. | Wheel appears near the cursor after the activation delay; Finder's drag remains active. |
| Real conversion | Hover Convert, move to WebP or PNG, release over that labeled outer option. | Wheel closes; progress/result appears; readable output exists beside the source or in configured Downloads; original checksum is unchanged. |
| Single action | Drop an eligible file on a one-action inner category. | Exactly that action runs once. |
| Cancellation | Repeat with center drop, ring-gap drop, outside drop, Escape, and modifier release before dropping. | No output is created; wheel closes. Releasing the mouse alone never executes. |
| Payload mismatch | Use Choose Files with one file, then drag a different file into its wheel. | Destination refuses the payload; selected preview does not authorize processing another file. |
| Picker fallback | Without global observation, Choose Files, then drag those same Finder files to a concrete target. | Drop works through the actual destination; picker selection alone does nothing. |
| Stale pasteboard | Complete/cancel a file drag, then drag unrelated text or move the mouse with Shift held. | Persistent old pasteboard contents do not reopen or execute the previous file action. |
| Pause and resume | Pause, attempt a drag, resume midway, then begin a new drag. | Paused/midgesture resume does not activate; a fresh eligible drag activates normally. |
| Trigger change | Toggle Require Shift + Option; try Shift alone and then Shift + Option. | Configured modifier is respected; no claim of extra advanced features. |
| Batch | Drag five still images and convert them; try a mixed selection and a folder. | All supported outputs appear; mixed selection offers common operations; folder offers ZIP creation. |
| Collision | Run the same action twice with an existing output of the same name. | Existing file remains intact; new output receives a numbered name. |
| Orientation/alpha | Convert an EXIF-rotated photo and a transparent PNG to JPEG/PNG/WebP. | Display orientation is upright; JPEG has the documented white transparency background; supported alpha output remains usable. |
| Privacy | Hold Shift + Option on a tagged still image; inspect its Privacy summary, then Remove GPS/Metadata and check output with an independent tool. | Privacy opens when offered; only category presence is shown, not values; uninspected formats are labeled; standard GPS data is absent from GPS result; pixels remain upright. No content-redaction promise is inferred. |
| Compression | Compress a large eligible image/video and an already compact input. | Smaller output is published when possible; non-smaller result returns an explanatory error without overwriting the original. |
| PDF | Merge two PDFs; split a multipage PDF; render pages to PNG; create PDF from images; extract text from a scanned page. | Correct page count/order and readable outputs; bounded rendering; OCR text reflects actual source; locked/corrupt PDFs report errors. |
| Media | Use a supported MOV/MP4 with audio and supported audio-only input. Convert/compress/extract; cancel a longer export. | Playable expected tracks/duration; unsupported media gives an explanation; cancellation cleans operation outputs and preserves originals. |
| ZIP | Create ZIP from a file/folder, then extract a supported archive. Run native archive tests for unsafe fixtures. | Separate ZIP per selected item; extracted tree matches safe contents; links/traversal/bomb/unsupported fixtures are refused. |
| General files | Duplicate, create SHA-256 manifest, format/minify valid JSON; try malformed JSON. | Correct independent output; checksum matches an independent tool; valid JSON decodes; invalid input leaves no reported successful output. |
| Results | Reveal, Copy, drag the first output, clear recent results, quit/relaunch. | Finder reveal and file-URL clipboard work; output can be dragged into another app; memory history clears on quit. |
| Undo unchanged file | Generate a regular file and use latest Undo. | Generated file moves to Trash; original remains; only latest operation is eligible. |
| Undo refusal | Modify/replace an output, or extract a folder and attempt Undo. | Changed/replaced/unverifiable files and all extracted directories are refused with a useful explanation. |
| Display edges | Activate near all four corners/menu bar/Dock on each display, including negative-origin layouts and mixed Retina scales. | All options fit the containing display's visible frame; hit tests match drawn targets in points. |
| Spaces/fullscreen | Test another Space, fullscreen app, Mission Control, and Stage Manager. | Panel visibility/dismissal is appropriate and never strands an active wheel or steals the source drag. |
| Accessibility | Test VoiceOver labels, Increase Contrast, Reduce Motion, arrow/number selection when focused, and Escape. | Actions have descriptive names; contrast/motion preferences apply; selection does not independently transform files; cancellation works. |
| Login/settings | Toggle launch at login, test system approval/failure status, change quality/output folder/sound, relaunch. | Supported preferences persist and affect actual operations; failed service registration is reported. |
| Resource behavior | Observe an idle session, repeated wheel activation, a large permitted input, and cancellation in Activity Monitor. | No unexplained idle polling/CPU growth; no orphan active job after cancellation. Record measurements rather than assuming performance targets are met. |

An acceptance failure should include the concrete input family, gesture steps, expected/actual behavior, and the relevant build/source revision. Native verification is complete only after these interactive outcomes have been recorded on a Mac.
