# CornerOrbit 0.2.0 evaluation

The release adds the [50 numbered features](FEATURES-0.2.0.md) within CornerOrbit only. The integrated Linux run passed 90 portable tests with Swift 6.2; the genuine macOS build and final evaluation are in progress. The release evidence and download will be updated after that build completes.

Independent review has added checks for profile-application publication failures, v0.1 migration, permission-preserving binding undo, timed pause/exclusions, practice cancellation and clipboard ownership. New native captures cover expanded settings and reviewed profile imports using labeled synthetic data. Tests do not grant permissions, access real Chrome profiles or execute personal Shortcuts.

The previous version’s files under docs/ are historical until replaced by this release’s actual CI artifacts. No v0.2.0 test count, package or preview result is claimed from those older artifacts. See known-limitations.md for physical Mac acceptance that automated fixtures cannot provide.
