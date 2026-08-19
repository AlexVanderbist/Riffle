# 3. The Directional Pinch reads raw touches from gesture events

Date: 2026-08-19

## Status

Accepted

## Context

A magnify event only carries a scalar magnification. To resize one axis at a time, Riffle needs the two finger positions. A three-finger swipe was tried first and rejected: the Dock handles three- and four-finger swipes through WindowServer's system-gesture path, which a session event tap cannot suppress, so Mission Control fired alongside the resize.

## Decision

Keep the two-finger pinch as the only resize input. `NSEvent(cgEvent:).allTouches()` on the tap's gesture events (type 29) provides the touches; the pure `TwoFingerSpread` tracker turns them into per-axis separation changes, and `PendingStretch` maps those to width and height with Gap Share positioning. It is a Preferences mode ("Directional Pinch") on the existing Resize Gesture, so the latch, chord gating and Target Window rules are unchanged.

## Consequences

- No private framework, no new gesture to fight the system over.
- Vertical pinches are less comfortable than horizontal ones; the feel constants in `StretchFeel` may need tuning once used in anger.
