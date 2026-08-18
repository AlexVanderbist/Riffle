# 1. Snap Gestures are layered on the Move Gesture

Date: 2026-08-17

## Status

Accepted

## Context

Riffle moves windows with a modifier-gated two-finger swipe. Users also want the common layouts (halves, quarters, maximized, centered) without a separate shortcut set. A throwaway prototype (branch `prototype/window-snapping`, commit "Prototype: window snap gestures") tested how snapping should feel on top of the existing gesture.

## Decision

- Snapping is detected from the Move Gesture's applied translations, not from a separate chord, drop zones, or a synthetic title-bar drag. `SnapDetector` is a pure state machine fed once per applied translation.
- Being pinned is what turns a push into a press. An axis is pinned when the constrained position stops changing (display edge, menu bar) **or** when the cursor is contained at a display edge in the push direction. The second rule matters because a window can slide mostly off-screen at the sides and bottom, so the window position alone pins too late.
- A press into the top maximizes; into a side gives that half; a clear sideways component during the press, or being pinned on both axes, gives the quarter in that direction. A window already filling a half turns up/down (press or flick) into the quarter on that side.
- A Flick is decided at finger lift from the last few samples; the session ends after it.
- Every mid-gesture snap keeps the gesture alive: `PendingMove` is rebased onto the snapped frame, the cursor keeps its place inside the frame (or is pulled just inside), the detector is reset, and translations settle briefly. Users can keep dragging or chain another snap without regrabbing.
- Non-resizable windows never snap; they still move.

## Consequences

- No new input path; the event tap and latch are unchanged.
- The Snap Display is chosen per snap by cursor, so multi-display behavior follows the cursor like the rest of the Move Gesture.
- Snap frames are AX writes like moves; apps that clamp sizes are re-read after the write and the move continues from the frame they accepted.
