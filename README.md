# OrbitDrop

OrbitDrop is a native macOS menu bar application for transforming local files through a radial drop target. It implements a focused subset of the supplied Orbit product specification; the advanced features in that specification are not all implemented.

Requires macOS 14 or later. The build uses Swift 6, AppKit, SwiftUI, and Apple media/document frameworks. The application icon adapts the Orbit logo supplied by the user.

## Build and open

On a Mac with Xcode 16 or later, CMake, Python 3, and Git:

```bash
bash Scripts/build.sh
open build/DerivedData/Build/Products/Release/OrbitDrop.app
```

The script tests the core and native engines, builds a universal `arm64`/`x86_64` application, signs it with an ad hoc signature, and writes `dist/OrbitDrop.app.zip` and its SHA-256 checksum. See [BUILD.md](BUILD.md) for prerequisites, CI retrieval through Git, and signing limits.

The Linux development host can run the portable core tests. It cannot compile or link AppKit, run Finder, or produce a validated native application. Interactive macOS acceptance is tracked in [MANUAL-ACCEPTANCE.md](MANUAL-ACCEPTANCE.md); automated results are recorded separately.

## Use

1. Open OrbitDrop; its controls live in the menu bar.
2. Use **Enable Input Monitoring**, then enable OrbitDrop in **System Settings → Privacy & Security → Input Monitoring**. macOS may require you to quit and reopen OrbitDrop. Permission must be granted through macOS; the app cannot grant it itself.
3. Begin dragging one or more local files from Finder or the Desktop, then hold **Shift**.
4. Hover a category in the inner ring. Choose a concrete format or action in the outer ring, and release the files over that target. A category with one action also accepts a direct drop.
5. Reveal, copy, or drag the latest result from **Results & Progress**.

The category positions stay fixed between sessions. Shift + Option opens Privacy when that category is available, using the same action set. Its compact image summary reports detected metadata categories without showing their values. Settings can require Shift + Option for activation.

Dropping in the center, the gaps, or outside the wheel cancels. Escape and releasing the trigger modifier cancel the presentation. Hovering or releasing the mouse elsewhere does not run a transformation. Number keys and arrows can change wheel selection when the panel receives keyboard focus; Return does not execute an action.

**Choose Files…** is available when global drag observation is unavailable. Choose the files, then start a real Finder drag of those same files into the displayed wheel. Choosing files alone does not process them, and the fallback is not a keyboard-only workflow.

## Available operations

The catalog contains 23 actions, filtered by the selected file types:

| Input | Operations |
| --- | --- |
| Still images | JPEG, PNG, HEIC, WebP; compress; resize to a maximum edge of 1600 px; remove metadata or GPS; images to PDF; extract text |
| PDFs | Merge two or more PDFs, split pages, render pages to PNG, extract text |
| Native video | Convert to H.264-compatible MP4, compress video, extract audio to M4A |
| Native audio | Convert to M4A when AVFoundation supports the source |
| ZIP | Extract the supported, strictly validated ZIP flavor |
| JSON | Format or minify valid JSON |
| General files | Create ZIP, SHA-256 checksum, duplicate |
| Folders | Create ZIP |

Mixed selections receive common file operations. Batch ZIP creation produces one archive per selected item. Existing outputs receive a numbered name rather than being replaced. Outputs are saved beside the originals by default; Settings can select Downloads. Originals are not overwritten by transformations.

Results are kept in memory. The default keeps the latest result for Undo; optional history holds up to 20 records and filters out entries older than 24 hours whenever read or updated. Quitting clears this state. Undo only applies to the latest operation, moves verified generated files to Trash, and refuses extracted folders.

Read [implemented-features.md](implemented-features.md), [known-limitations.md](known-limitations.md), [ARCHITECTURE.md](ARCHITECTURE.md), and [SECURITY.md](SECURITY.md) for the exact scope and behavior.
