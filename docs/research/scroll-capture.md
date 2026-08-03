# Research: capturing modifier-gated two-finger scroll globally

Resolves issue #2. Question: what is the reliable mechanism to observe **and consume** two-finger
trackpad scrolling system-wide while Ctrl+Shift is held, so the swipe moves a window instead of
scrolling the app under the cursor?

## Verdict

Use a single **active (`kCGEventTapOptionDefault`) CGEventTap on `kCGEventScrollWheel`**, created
with `CGEventTapCreate`, added to a run loop via `CFMachPortCreateRunLoopSource`. In the callback:

1. If `type` is `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput`, call
   `CGEventTapEnable(tap, true)` and return the event.
2. Read modifiers off the scroll event itself with `CGEventGetFlags(event)` (every CGEvent carries
   flags — no separate `flagsChanged` tap needed, which keeps Riffle out of keyboard-event/Input
   Monitoring territory).
3. Identify trackpad-style scrolling via `kCGScrollWheelEventIsContinuous != 0`.
4. Latch capture at gesture start (`kCGScrollWheelEventScrollPhase == kCGScrollPhaseBegan` with
   Ctrl+Shift down), move the window by `kCGScrollWheelEventPointDeltaAxis1/2` (pixel deltas), and
   **return `NULL` from the callback to delete the event** so the app under the cursor never sees it.
5. Keep swallowing the gesture — including the momentum tail — until
   `kCGScrollWheelEventMomentumPhase` reaches `kCGMomentumScrollPhaseEnd`, even if the modifiers
   are released mid-swipe.

This is exactly the architecture used by Scroll Reverser, Mos, and LinearMouse (all active
scroll-wheel taps that inspect/modify/drop events), and by Easy Move+Resize for its mouse-event
variant of the same "modifier-gated window move" idea.

## API details (primary sources)

### Creating the tap

`CGEventTapCreate(tap, place, options, eventsOfInterest, callback, userInfo)` returns a
`CFMachPortRef` (or `NULL` on failure). From `CGEvent.h` (MacOSX SDK):

> "Taps may be passive event listeners, or active filters. An active filter may pass an event
> through unmodified, modify an event, or discard an event." — `CGEvent.h`

- **Event mask**: `CGEventMaskBit(kCGEventScrollWheel)` (`kCGEventScrollWheel = NX_SCROLLWHEELMOVED`,
  `CGEventTypes.h`).
- **Options**: `kCGEventTapOptionDefault = 0` (active filter) vs `kCGEventTapOptionListenOnly = 1`
  (`CGEventTypes.h`). Only a default tap can consume events; a listen-only tap's return value is
  ignored.
- **Location**: `kCGSessionEventTap` is the safe documented choice for a non-root app. Apple's
  `CGEventTapCreate` docs state: "Only processes running as the root user may locate an event tap
  at the point where HID events enter the window server; for other users, this function returns
  NULL" — in practice apps holding Accessibility can create `kCGHIDEventTap` taps (LinearMouse does),
  but the documented-safe options are session-level. Real-world choices:
  - Scroll Reverser: `kCGSessionEventTap` + `kCGTailAppendEventTap` (`MouseTap.m`).
  - Mos: `cgAnnotatedSessionEventTap` + `tailAppendEventTap` (`ScrollCore.swift`).
  - LinearMouse: `cghidEventTap` + `headInsertEventTap` (`EventTap.swift`).
  For Riffle, `kCGSessionEventTap` + `kCGHeadInsertEventTap` (see the event before other session
  filters) is a sound default.
- **Run loop**: `CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)` then
  `CFRunLoopAddSource(..., .commonModes)`. The callback runs on the run loop the source is added to
  ("The event tap callback runs from the CFRunLoop to which the tap CFMachPort is added as a
  source." — `CGEvent.h`). LinearMouse runs its tap on a dedicated thread (`EventThread`) so
  main-thread stalls can't cause tap timeouts; a good pattern if the AX window-move work is done
  synchronously in the callback.

### Consuming events: return NULL

From the `CGEventTapCallBack` typedef comment in `CGEventTypes.h`:

> "The function should return the (possibly modified) passed-in event, a newly constructed event,
> or NULL if the event is to be deleted."

In Swift the callback returns `Unmanaged<CGEvent>?`; return `nil` to swallow, otherwise
`Unmanaged.passUnretained(event)` (or `passRetained` for a newly created event — see LinearMouse
`EventTap.swift` `callbackInvoker` for exact ownership handling). Mos's scroll callback returns
`nil` when it takes over an event for smooth-scroll posting (`ScrollCore.swift`).

### Trackpad vs mouse wheel

- `kCGScrollWheelEventIsContinuous = 88` (`CGEventTypes.h`): "indicates whether a scrolling event
  contains continuous, pixel-based scrolling data. The value is non-zero when the scrolling data is
  pixel-based and zero when the scrolling data is line-based." Trackpad and Magic Mouse scrolling is
  continuous; classic wheel mice are line-based. Scroll Reverser: "assume anything not-continuous is
  a mouse" (`MouseTap.m`).
- Continuous alone does not separate trackpad from Magic Mouse. If that ever matters, Mos treats an
  event as trackpad when `scrollWheelEventMomentumPhase != 0 || scrollWheelEventScrollPhase != 0`
  (or non-zero `scrollWheelEventScrollCount`) (`ScrollEvent.swift`); Scroll Reverser counts touches
  with a *separate listen-only* tap on `NSEventMaskGesture` (`MouseTap.m`). For Riffle the intent
  signal is Ctrl+Shift, so "continuous + phases present" is sufficient; hijacking a Ctrl+Shift Magic
  Mouse swipe would arguably even be correct behavior.

### Phase fields

From `CGEventTypes.h`:

- `kCGScrollWheelEventScrollPhase = 99`, values `CGScrollPhase`:
  `kCGScrollPhaseBegan = 1, Changed = 2, Ended = 4, Cancelled = 8, MayBegin = 128` (a bitmask-style
  set matching `NSEvent.phase` / `NSEventPhase`).
- `kCGScrollWheelEventMomentumPhase = 123`, values `CGMomentumScrollPhase`:
  `None = 0, Begin = 1, Continue = 2, End = 3` (**a different, sequential value set** — do not reuse
  the `CGScrollPhase` constants for it).

Lifecycle of a two-finger swipe with a fling: fingers-down events carry
`scrollPhase = MayBegin/Began/Changed.../Ended` with `momentumPhase = None`; after fingers lift, the
system keeps generating scroll events with `scrollPhase = 0` and
`momentumPhase = Begin, Continue..., End`. Apple (NSEvent.momentumPhase): "the user can use a scroll
wheel or flick gesture resulting in a stream of scroll events that dissipate over time... attached
to the view that is under the cursor when the flick occurs."

### Deltas: line vs pixel

From `CGEventTypes.h` (axis 1 = vertical, axis 2 = horizontal):

- `kCGScrollWheelEventDeltaAxis1/2` (11/12) — integer **line-based** deltas (wheel clicks; coarse).
- `kCGScrollWheelEventFixedPtDeltaAxis1/2` (93/94) — 16.16 fixed-point deltas; read with
  `CGEventGetDoubleValueField` for the fractional value.
- `kCGScrollWheelEventPointDeltaAxis1/2` (96/97) — integer **pixel-based** deltas.

For moving a window, use `PointDeltaAxis1/2` (screen-pixel scale, matches finger motion). If a
mouse-wheel fallback is ever added, `DeltaAxis1 * someStep` is the right unit there.

Note (only relevant when *modifying* rather than deleting events): setting `DeltaAxis` causes macOS
to internally recompute `PointDeltaAxis` (8x) and `FixedPtDeltaAxis` (1x), so set the point values
after — documented in a Scroll Reverser comment (`MouseTap.m`).

### Natural scrolling

The deltas in the event are **already inverted according to the user's "natural scrolling"
preference**. Apple (NSEvent.isDirectionInvertedFromDevice): scrolling delta values "are
automatically inverted for NSEventScrollWheel events according to the user's preferences. ... This
property allows you to determine when the event has been inverted and compensate by multiplying by
-1 if needed."

There is no public `CGEventField` for this; bridge with `NSEvent(cgEvent:)` and read
`isDirectionInvertedFromDevice` (exactly what Scroll Reverser does:
`[[NSEvent eventWithCGEvent:eventRef] isDirectionInvertedFromDevice]`, `MouseTap.m`). Riffle should
normalize so "fingers move right → window moves right" regardless of the preference:
`fingerDelta = inverted ? delta : -delta` (verify the sign empirically on first implementation; the
mechanism — one flag, one conditional negation — is the load-bearing part).

## Gating on Ctrl+Shift and the momentum tail

- **Latch at gesture start.** Check `CGEventGetFlags(event)` for
  `.maskControl | .maskShift` when `scrollPhase == Began` (or `MayBegin`) and set a `capturing`
  flag. While capturing, return `NULL` for every scroll event of the gesture. Do **not** re-evaluate
  modifiers per event as the sole criterion:
  - A gesture that started *without* the modifiers must never be hijacked mid-flight.
  - A gesture that started *with* them must keep being swallowed after the user releases Ctrl+Shift
    mid-swipe — otherwise the app under the cursor suddenly receives an orphan stream (mid-gesture
    `Changed` events or a headless momentum tail), which scrolls it unexpectedly.
- **Momentum tail.** After fingers lift, momentum events continue arriving with
  `momentumPhase = Begin/Continue/End` and no modifiers required. If the gesture was captured, keep
  swallowing until `momentumPhase == kCGMomentumScrollPhaseEnd` (or a new `scrollPhase == Began`
  arrives), then clear `capturing`. Simplest policy: drop the tail entirely (window stops when
  fingers lift); optionally apply it for a "glide" effect later.
- Because modifier state is read from the scroll events' own flag bits, no `flagsChanged`/`keyDown`
  tap is needed at all.

## Permissions

- **Accessibility (TCC "Accessibility") is the gate for an active scroll tap.** Check/prompt via
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` (used by Easy Move+Resize,
  LinearMouse, Mos, Scroll Reverser). Riffle needs this anyway for AX window moving, so the tap adds
  no extra prompt. Without it, `CGEventTapCreate` clears unpermitted bits from the mask and returns
  `NULL` when the mask ends up empty (`CGEvent.h`).
- **Input Monitoring (10.15+)** is the separate gate for listen-only taps and keyboard-event
  monitoring: `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` (`CGEvent.h`,
  macos(10.15)), equivalently `IOHIDCheckAccess/IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`.
  Scroll Reverser checks both only because it also runs a listen-only `NSEventMaskGesture` tap
  (`PermissionsManager.m`); Mos ships with Accessibility alone for its active scroll tap. As long as
  Riffle taps only `scrollWheel` with a default tap, Accessibility is sufficient.
- **Revocation**: if the user revokes Accessibility while running, the tap dies silently. Mos's
  `Interceptor` polls `AXIsProcessTrusted()` on a 5 s timer and stops/notifies instead of blindly
  re-enabling (`Interceptor.swift`).

## Tap timeout and re-enable

From `CGEventTypes.h`: "Out of band event types. These are delivered to the event tap callback to
notify it of unusual conditions that disable the event tap": `kCGEventTapDisabledByTimeout =
0xFFFFFFFE`, `kCGEventTapDisabledByUserInput = 0xFFFFFFFF`. From `CGEvent.h`
(`CGEventTapEnable`): "If a tap becomes unresponsive or a user requests taps be disabled, an
appropriate `kCGEventTapDisabled...` event is passed to the registered CGEventTapCallBack function.
An event tap may be re-enabled by calling this function."

Every studied implementation handles this:

- Easy Move+Resize: `if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) { CGEventTapEnable([moveResize eventTap], true); }` (`EMRAppDelegate.m`).
- LinearMouse: re-enables on `tapDisabledByTimeout` inside the callback **and** runs a 5 s health
  timer calling `CGEvent.tapIsEnabled` / `tapEnable`, plus a 10 s watchdog that recreates the tap if
  the mach port went invalid (`EventTap.swift`, `GlobalEventTapWatchdog.swift`).
- Mos: 5 s "keeper" timer with restart throttling (max 3 restarts/60 s) to avoid re-freezing input
  when the main thread is blocked, e.g. by a TCC dialog (`Interceptor.swift`).
- Scroll Reverser: re-enables both taps whenever the callback sees a non-scroll/non-gesture type
  (`MouseTap.m` `enableTap`).

Riffle should do both: re-enable inline on the disabled event types, and run a periodic
`CGEventTapIsEnabled` check. The real defense is keeping the callback fast — the timeout fires when
the callback stalls the event pipeline. Cache the target `AXUIElement` window once at
`scrollPhaseBegan` (one hit test), then only issue `AXUIElementSetAttributeValue(position)` per
event; never do blocking work in the callback.

## Pitfalls summary

1. **Momentum tail leak** — swallow through `momentumPhase == End` even after modifiers release
   (see above).
2. **Don't hijack mid-gesture** — capture decision only at `scrollPhase Began/MayBegin`.
3. **`momentumPhase` and `scrollPhase` use different value sets** (sequential 0-3 vs bitmask).
4. **Do not tap gesture/touch events with an active tap.** Scroll Reverser comment: doing so
   "Triggers additional permissions dialogs..., Interferes with 'shake to locate cursor',
   Interferes with the 2-finger 'show notification center' gesture" (`MouseTap.m`) — if touch
   counting is ever needed, use a second listen-only tap (which then wants Input Monitoring).
5. **Slow callback ⇒ `kCGEventTapDisabledByTimeout`** — keep AX work minimal, consider a dedicated
   tap thread (LinearMouse `EventThread`).
6. **Tap creation returns NULL without Accessibility** — preflight with
   `AXIsProcessTrustedWithOptions` and poll for revocation.
7. **Synthesized-event loops** — if Riffle ever posts its own events, tag them via
   `CGEventSourceUserData`/source PID (`kCGEventSourceUnixProcessID`) and skip them in the callback
   (Mos does this for its smooth-scroll output).
8. **Natural scrolling flips deltas** — normalize with `NSEvent.isDirectionInvertedFromDevice` so
   window motion follows the fingers for every user setting.

## Sources

Apple headers (MacOSX SDK, `/Applications/Xcode.app/.../MacOSX.sdk/System/Library/Frameworks/CoreGraphics.framework/Headers/`):

- `CGEventTypes.h` — `CGEventField` scroll constants (`kCGScrollWheelEventIsContinuous` = 88,
  `DeltaAxis1/2` = 11/12, `FixedPtDeltaAxis1/2` = 93/94, `PointDeltaAxis1/2` = 96/97,
  `ScrollPhase` = 99, `MomentumPhase` = 123), `CGScrollPhase`/`CGMomentumScrollPhase` enums,
  `kCGEventTapDisabledByTimeout/ByUserInput`, `CGEventTapOptions`, `CGEventTapCallBack` contract.
- `CGEvent.h` — event-tap overview (active filter may "discard an event"), `CGEventTapCreate`,
  `CGEventTapEnable`, `CGPreflightListenEventAccess`/`CGRequestListenEventAccess` (macos 10.15).

Apple documentation:

- CGEventTapCreate — https://developer.apple.com/documentation/coregraphics/cgeventtapcreate(_:_:_:_:_:_:)
- CGEventTapCallBack — https://developer.apple.com/documentation/coregraphics/cgeventtapcallback
- kCGScrollWheelEventIsContinuous — https://developer.apple.com/documentation/coregraphics/cgeventfield/kcgscrollwheeleventiscontinuous
- NSEvent.isDirectionInvertedFromDevice — https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice
- NSEvent.momentumPhase — https://developer.apple.com/documentation/appkit/nsevent/momentumphase
- CGRequestListenEventAccess — https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess

Implementations:

- Scroll Reverser (pilotmoon) — https://github.com/pilotmoon/Scroll-Reverser/blob/master/MouseTap.m and
  https://github.com/pilotmoon/Scroll-Reverser/blob/master/PermissionsManager.m
- Mos (Caldis) — https://github.com/Caldis/Mos/blob/master/Mos/ScrollCore/ScrollCore.swift ,
  https://github.com/Caldis/Mos/blob/master/Mos/ScrollCore/ScrollEvent.swift ,
  https://github.com/Caldis/Mos/blob/master/Mos/Utils/Interceptor.swift
- LinearMouse — https://github.com/linearmouse/linearmouse/blob/main/LinearMouse/EventTap/EventTap.swift ,
  https://github.com/linearmouse/linearmouse/blob/main/LinearMouse/EventTap/GlobalEventTap.swift ,
  https://github.com/linearmouse/linearmouse/blob/main/LinearMouse/EventTap/GlobalEventTapWatchdog.swift
- Easy Move+Resize (dmarcotte) — https://github.com/dmarcotte/easy-move-resize/blob/main/easy-move-resize/EMRAppDelegate.m
- pqrs-org event-observer comparison (permissions matrix) — https://github.com/pqrs-org/osx-event-observer-examples
