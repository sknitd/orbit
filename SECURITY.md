# Security and privacy

OrbitDrop processes local files on the Mac. This implementation has no runtime upload, analytics, cloud AI, or remote conversion service. Build-time dependency retrieval from GitHub is separate from application processing.

## Input observation

The public Core Graphics tap is listen-only. It observes mouse drag lifecycle, modifier flags, and the hardware Escape key code. It does not read keyboard characters, change input events, or inspect another application's document contents. Input Monitoring permission is requested through macOS and may require a relaunch. Accessibility control permission is not used by this implementation.

A global file-drag candidate is not proof of a drop. The AppKit destination reads the actual drag-session URLs, checks that their canonical paths match the inspected preview, rejects duplicates and nonlocal URLs, and requires an eligible wedge. Mouse-up, hover, and keyboard selection cannot independently execute a file operation. The application then reinspects the authoritative URLs and checks the selected capability again.

## File handling

- File inspection rejects symbolic links, unreadable inputs, and special files. Folder ZIP creation also rejects links and special files inside the tree.
- Paths are passed as data to Foundation or fixed subprocess argument arrays. File names are never interpolated into shell commands. Archive processes use macOS system executables.
- Generated content is staged in a private directory with mode `0700`. Final regular files use private permissions, retaining only an existing owner-execute bit where appropriate.
- Output names are validated. Exclusive rename publishes a new result; collisions receive numbered names. An operation cannot replace an existing input or output through the transaction's commit path.
- Cancellation and failure attempt to remove staging and outputs created by that operation. A crash or forced termination can leave a private staging directory; automatic recovery cleanup is not implemented.

## ZIP policy

Extraction supports classic, single-disk ZIP with stored or deflated entries and unambiguous ASCII/UTF-8 names. It rejects ZIP64, encryption, split archives, links, special files, privileged permissions, path traversal, absolute/ambiguous paths, conflicting case/Unicode names, mismatched headers, hidden records, and unsupported extra metadata.

Limits are 10,000 archive entries, 2 GiB total expanded bytes, 512 MiB per entry, and a maximum 200:1 declared compression ratio. The engine copies an extraction source to a private read-only snapshot, validates exactly that snapshot, monitors actual expansion, and verifies the extracted tree before publication. These restrictions intentionally reject some otherwise valid ZIP files. The implementation is not a general archive-format extractor or a substitute for independent security review.

## Metadata, history, and Undo

Remove Metadata rebuilds a still image without its input property dictionaries while preserving upright display and color handling. Remove GPS removes the standard GPS dictionary and checks its absence in supported ImageIO output. These actions do not redact visible content, inspect every possible embedded payload, remove filesystem attributes from the original, or provide a forensic privacy guarantee. Lossy formats can be reencoded.

The wheel's compact Privacy summary reports the presence of standard GPS and selected EXIF/TIFF details without displaying their values. WebP and multiframe metadata are marked uninspected. An absent detected category is not proof that every metadata container is clean.

Preferences persist in `UserDefaults`; result history does not persist. The default keeps only the latest result. Optional history stores up to 20 records in memory and filters entries older than 24 hours on every read and insertion. There is no background expiration timer; expired records can remain in backing memory until insertion, clearing, or quitting. It contains file URLs and result metadata, not a document-content database. Clipboard writing occurs only when **Copy** is selected.

Undo moves generated regular files to Trash after checking resource identity, size, and modification date. It refuses directories, symbolic links, changed files, and unavailable metadata. It is not a content-hash comparison: edits preserving the checked values cannot be detected. Trash operations can partly succeed before a filesystem error; the interface reports that condition. Only the latest operation is eligible.

## Distribution and dependencies

The developer build is ad hoc signed. Developer ID signing, notarization, hardened-runtime distribution policy, and App Store sandboxing are not configured. No Gatekeeper or signature-verification bypass is part of the build instructions.

WebP uses statically linked libwebp source pinned to commit `a4d7a715337ded4451fec90ff8ce79728e04126c` from `webmproject/libwebp`. The build preserves TLS verification, checks the selected Git commit, and includes upstream BSD license and patent notices in the application. Dependency updates require explicit review and native revalidation.

For a suspected issue, preserve the affected inputs, application version, macOS version, and steps to reproduce. Share confidential files only through a channel you have deliberately chosen. This repository does not configure a private vulnerability-reporting inbox.
