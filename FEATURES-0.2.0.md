# CornerOrbit 0.2.0 — 50 additions

This release adds the following 50 features to CornerOrbit 0.1.0. Related gesture families and formatting modes are grouped as one feature. Implementation and acceptance evidence is recorded in [EVALUATION.md](EVALUATION.md).

## Profiles and controls

1. Named gesture profiles with create, rename and delete.
2. Duplicate a profile to customize a copy.
3. Import profiles from JSON with an explicit review before adding them.
4. Export profiles to JSON, excluding monitoring and Automation consent.
5. Optional frontmost-app rules that select a saved profile.
6. Excluded apps that suspend corner recognition.
7. Timed gesture pause with explicit early resume.
8. Optional launch at login through macOS Service Management.
9. Search the action catalog by name, category and purpose.
10. Undo and redo binding edits without reverting permission choices.

## Gestures

11. Right-button single, double and triple clicks.
12. Middle-button click.
13. Hover dwell, once per corner entry.
14. Press and hold, with click/drag suppression after recognition.
15. Scroll up and down gestures.
16. Per-corner active-area sizes.
17. Per-corner modifier requirements.
18. Practice mode that reports recognized gestures without executing their actions.

## Window controls

19. Snap the front window to the left half.
20. Snap the front window to the right half.
21. Maximize within the display's usable area.
22. Center the front window without resizing it.
23. Move the front window to the next display.
24. Restore a window's previous frame.
25. Minimize the front window.
26. Toggle the front window's fullscreen state.
27. Hide other regular applications.
28. Restore only applications hidden by CornerOrbit.

## Mac and browser actions

29. Open a private Chrome window.
30. Search Google in Chrome for explicitly read clipboard text.
31. Open a new Safari tab.
32. Open a new Finder window.
33. Create a new TextEdit draft from clipboard text.
34. Create a blank Pages document.
35. Create a blank Numbers spreadsheet.
36. Create a blank Keynote presentation.
37. Run a chosen macOS Shortcut by name.
38. Open the macOS Screenshot toolbar.
39. Start the macOS screen saver.
40. Open a saved file or folder.

## Local links and clipboard

41. Favorite websites with editing, ordering, search and a dropdown.
42. Named groups of websites opened by one configured action.
43. Plain-text clipboard cleanup.
44. JSON prettify and minify, with validation.
45. URL component encoding and decoding.
46. Base64 text encoding and decoding.
47. Upper, lower, title, snake and kebab case conversion.
48. Strip tracking parameters from a web URL.
49. Trim and deduplicate lines while preserving their order.
50. Undo the last clipboard transform if the clipboard has not since changed.

All additions remain inside CornerOrbit. macOS 14 and universal Intel/Apple silicon support, explicit permission requests, local storage, visible errors and the existing app boundaries are retained. No permission, app launch, clipboard read, website open or Shortcut execution is triggered merely by importing or editing a binding.
