# Orbit

Three native macOS utilities share local file transformation engines:

| App | How to open file actions | Download and setup |
| --- | --- | --- |
| **NotchOrbitPlus** | 22 tools, live music/meeting/progress status, Quick Launcher, saved drop workflows, shelf organization, clipboard OCR and optional sync. | [Download NotchOrbitPlus.app.zip](https://github.com/sknitd/orbit/raw/33b34fdbbdb8770046b69861aa1f0ea375338aec/NotchOrbitPlus.app.zip) · [Features and setup](NotchOrbitPlus/README.md) |
| **NotchOrbit** | Drag files toward the MacBook notch or display's top center. No modifier key; actions appear in a native semicircle. | [Download NotchOrbit.app.zip](https://github.com/sknitd/orbit/raw/22d4fddbf7dda0beb49e88219c3087a5f6a63f83/NotchOrbit.app.zip) · [Setup and preview](NotchOrbit/README.md) |
| **OrbitDrop** | Drag files and hold Shift to open a radial wheel near the pointer. | [OrbitDrop download and installation](#download-and-install) |

NotchOrbit and NotchOrbitPlus have separate projects, app bundles, preferences and storage in [NotchOrbit/](NotchOrbit/) and [NotchOrbitPlus/](NotchOrbitPlus/). All three apps target macOS 14 or later on Apple Silicon and Intel. NotchOrbitPlus's on-device AI additionally requires an eligible macOS 26+ Apple Intelligence configuration.

## OrbitDrop

OrbitDrop is a native macOS menu bar application for transforming local files through a radial drop target. It implements a focused subset of the supplied Orbit product specification; the advanced features in that specification are not all implemented.

Requires macOS 14 or later. The build uses Swift 6, AppKit, SwiftUI, and Apple media/document frameworks. The application icon adapts the Orbit logo supplied by the user.

## Download and install

[**Download OrbitDrop.app.zip**](https://github.com/sknitd/orbit/raw/ab7f06c2c843c0b5935a27fe9af26734ebec3a1e/OrbitDrop.app.zip) · [SHA-256 checksum](https://github.com/sknitd/orbit/blob/ab7f06c2c843c0b5935a27fe9af26734ebec3a1e/OrbitDrop.app.zip.sha256)

The prebuilt app supports **Apple Silicon and Intel Macs running macOS 14 or later**. Xcode, Swift, and CMake are only needed to build from source; they are not required to use the downloaded app. If the repository is private, sign in to GitHub with an account that has access before downloading.

1. Download the ZIP on your Mac and double-click it to extract **OrbitDrop.app**.
2. Move the entire app bundle into **Applications** and open it. OrbitDrop runs in the menu bar.
3. This development build is ad hoc signed and **not notarized**. If macOS blocks it, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** if offered.
4. In OrbitDrop's welcome window, click **Enable Input Monitoring**. Enable OrbitDrop under **System Settings → Privacy & Security → Input Monitoring**, then quit and reopen it if required. Each Mac needs its own permission grant.
5. Start dragging a JPEG from Finder, hold **Shift**, hover **Convert**, move to **WebP**, and release over that option. The converted file is saved beside the original by default; click **Reveal** in the results window to find it.

To copy OrbitDrop to another supported Mac, transfer the ZIP and extract it there, or copy the entire `.app` bundle. Grant Input Monitoring on that Mac as well.

This download is version **0.1.0**, built from source commit `63ba651111477c9c2403e05e1bfa185ad5a9b300` by [macOS CI run 36988372694](https://github.com/sknitd/orbit/actions/runs/36988372694). All **37 core and 33 native tests passed**, along with the universal Release build, signature verification, and a three-second startup check. Interactive Finder, Spaces, accessibility, and performance acceptance remain pending; see [test-results.md](test-results.md) and [MANUAL-ACCEPTANCE.md](MANUAL-ACCEPTANCE.md).

The ZIP's SHA-256 is:

```text
9459845bcbd6216425eadd5d58b067901784c509f20550818d56251168eeeba6
```

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
