# Riffle

Riffle is a macOS utility for moving and resizing another application's window through modifier-gated trackpad gestures.

## Language

**Target Window**:
The window beneath the cursor when a gesture begins. It remains the target until that gesture ends.
_Avoid_: Active Window, Focused Window, Frontmost Window

**System-managed Window**:
A full-screen or Split View window whose placement is controlled by macOS rather than Riffle.

**Move Gesture**:
A modifier-gated two-finger swipe that repositions the Target Window without a click.
_Avoid_: Drag Gesture, Scroll Gesture

**Resize Gesture**:
A modifier-gated two-finger pinch that proportionally resizes the Target Window around its center.
_Avoid_: Zoom Gesture

**Resize Display**:
The display containing the Target Window's center when a Resize Gesture begins. If the center is outside every display, it is the display containing the cursor.

**Snap Gesture**:
A Move Gesture that places the Target Window into a Snap Layout. Four kinds: Flick (fingers lift while still moving fast), Edge Press (pushing into a Pinned Axis), Corner Press (an Edge Press with a clear sideways component, or pinned on both axes), Wiggle (rapid horizontal reversals). Each kind can be switched off in Preferences.
_Avoid_: Tiling, Docking, Aero Snap

**Snap Layout**:
One of: left half, right half, maximized, top-left / top-right / bottom-left / bottom-right quarter, 80% centered. Always expressed inside the Snap Display's visible frame (menu bar and Dock removed).

**Snap Display**:
The display containing the cursor when a Snap Gesture fires. If no display contains the cursor, the Resize Display rule applied to the Target Window's frame at gesture start.

**Pinned Axis**:
An axis on which a Move Gesture's translation no longer moves the Target Window: the position is clamped by a display edge or the menu bar, or the cursor is contained at a display edge. Press pressure only accumulates on a Pinned Axis.

**Settle**:
The short period after a mid-gesture snap during which translations are ignored, so the tail of the push does not drag the snapped window away.
