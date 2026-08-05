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
