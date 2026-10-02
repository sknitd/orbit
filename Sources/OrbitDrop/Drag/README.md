# Drag observation contract

`DragMonitor` uses a public Core Graphics **listen-only** event tap. Its source
runs on the main run loop in common modes. It receives mouse-down, drag,
mouse-up, modifier changes, and the hardware Escape key code. It does not read
keyboard text, change input events, inspect other applications, or poll while
idle. The only timers are a configurable activation delay during an eligible
drag and one-shot cleanup after a drag release.

Before offering actions, the monitor requires a mouse-down observed by this
instance, a subsequent left-mouse drag event, a drag pasteboard that changed
since that mouse-down, and a real file URL representation on that board. It
does not accept the previous drag's persistent pasteboard contents. A second
pasteboard writer invalidates the gesture. The monitor is deliberately
conservative: starting or unpausing the application midway through a drag,
file promises without existing file URLs, text/image-only pasteboard drags,
and apps that reuse a previous drag pasteboard without writing a new payload
will not activate the wheel. Finder/Desktop file URL drags are the primary
workflow to validate on macOS.

There is no public system-wide `NSDraggingSession` observer. A fresh file drag
pasteboard plus the physical drag gesture is therefore a **candidate**, not
proof that a drop has happened. `NSDraggingDestination` must reread its actual
`NSDraggingInfo.draggingPasteboard`, determine a compatible action, validate
its selected wedge, and execute only from `performDragOperation`. A mouse-up
in the monitor never executes anything. Its cancellation is deferred 250 ms
because the tap sees the release before AppKit dispatches the drop. The
destination should hide from `draggingEnded` and notify `finishDrag()` after
completion, which cancels that one-shot fallback.

Shift activates the basic wheel and Shift+Option selects advanced actions.
`trigger` can be customized using Shift, Option, Control, and Command. When
Option is held, the callback's `advanced` argument is true. `activationDelay`
is measured in seconds, bounded to 0...2, and zero disables the delay. Pausing
disables the event tap and cancels the current gesture; resuming waits for a
new mouse-down. Escape cancels a candidate drag and cannot run an operation.

The activation position is `NSEvent.mouseLocation`: AppKit global **points**,
with a lower-left origin on the primary display and potentially negative
coordinates on other displays. The wheel should clamp its frame to the
containing display's `visibleFrame`. Avoid a second coordinate flip or using
pixel dimensions on Retina displays. The anchor is stable during a gesture,
including when Option changes the action set.

Input Monitoring in macOS Privacy & Security governs the listening permission
for this tap. `start()` attempts the public tap and reports `status`; it does
not prompt. An explicit setup/settings control can call
`requestInputMonitoringAccess()` (`CGRequestListenEventAccess`). Permission
changes may require quitting and relaunching the application. A listen-only
tap does not justify an Accessibility prompt for controlling other apps;
Accessibility would be a separate requirement for any future AX feature.
Secure-input sessions and system restrictions can make observation
unavailable even after a permission grant. The application must retain a
normal file picker/drop-zone workflow when a global tap cannot be created.

The Linux cloud host cannot run Finder/AppKit, confirm TCC prompts, establish
idle CPU, or exercise the drag server. Release acceptance still requires a
macOS build and a real Finder drop test on both one display and multiple
displays, including Escape, modifier release, dropping outside a wedge,
stale-pasteboard reuse, and five-file selection.
