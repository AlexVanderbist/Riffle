# Research: capturing the two-finger pinch gesture globally

Resolves [#3](https://github.com/AlexVanderbist/Riffle/issues/3). Question: can Riffle, as a background app, observe **and consume** the trackpad pinch/magnify gesture system-wide, for `Ctrl+Shift + pinch = resize`?

## Verdict

**Feasible with caveats.** A CGEventTap *can* see the undocumented gesture event (CGEvent type 29 == `NSEventTypeGesture`) system-wide, and the event can be read via `NSEvent(cgEvent:)` and deleted by returning `nil` from an active tap — this is shipping, working code in Hammerspoon. The caveats are that the event type is undocumented at the CoreGraphics level, there is a documented history (Mojave era) of gesture-event taps intermittently breaking native trackpad gestures system-wide, and magnify events are only generated at all when "Zoom in or out" is enabled in Trackpad settings.

**Recommended approach:** extend Riffle's existing event tap mask with `1 << 29` and handle magnify there (smallest change, one pipeline, consumption for free) — behind a short verification spike on current macOS. If the spike shows flakiness, fall back to the **Penc-style transparent overlay window**, a 100%-public-API pattern proven by an open-source app that does exactly Riffle's use case (trackpad pinch-to-resize of windows). The private MultitouchSupport route is observe-only (cannot consume) and is not needed here. Last-resort fallback: a second modifier + two-finger swipe for resize, which reuses the already-proven scroll-tap machinery.

---

## Route A — CGEventTap on gesture events (CGEvent type 29)

### Mechanics

- AppKit publicly defines `NSEventTypeGesture = 29`, `NSEventTypeMagnify = 30`, and `NSEventMaskGesture = 1ULL << 29` (verified in `AppKit.framework/Headers/NSEvent.h`, macOS SDK; both types available since 10.5). CoreGraphics' `CGEventType` enum has **no** constant for 29 — the gesture event type is undocumented at the tap level. (Interestingly, current SDKs *do* now publicly declare a `CGGesturePhase` enum in `CGEventTypes.h`, so Apple is slowly acknowledging gestures at the CG layer.)
- A session-level tap created with `CGEventTapCreate(kCGSessionEventTap, ..., kCGEventTapOptionDefault, mask, ...)` where `mask` includes `CGEventMask(1) << 29` receives these events. Hammerspoon's `hs.eventtap` does exactly this: its event-types table exposes `gesture = NSEventTypeGesture` for tap masks, and its tap is a session tap with `kCGEventTapOptionDefault` ([libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m), [libeventtap_event.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap_event.m)).
- **Reading magnification:** convert the tapped `CGEvent` with `NSEvent(cgEvent:)`. For a CGEvent of type 29, the resulting NSEvent's `.type` resolves to the concrete gesture (`.magnify`, `.rotate`, `.pressure`, ...), and for magnify you read `.magnification` (the per-event delta to add to the current scale) and `.phase`. This is exactly what Hammerspoon's `getTouchDetails()` does:

  ```objc
  NSEvent *asNSEvent = [NSEvent eventWithCGEvent:event];
  if (CGEventGetType(event) == NSEventTypeGesture) {
      if (asNSEvent.type == NSEventTypeMagnify) {
          // asNSEvent.magnification
      }
  }
  ```

  `allTouches` on the converted event even yields per-finger `NSTouch` data. Modifier state (Ctrl+Shift) is available on any tapped event via `CGEventGetFlags`.
- **Raw fields (if NSEvent conversion is ever insufficient):** the Calf Trail `TouchEvents` library vendored in Hammerspoon (reverse-engineered gesture synthesis, used by `hs.eventtap.event.newGesture`) shows the internal CGEvent field layout: integer field `0x6E` (110) = gesture subtype with `kTLInfoSubtypeMagnify = 0x08` (the "magnify subtype 8" from the ticket), float field `0x71` (113) = magnification, integer field `0x84` (132) = gesture phase ([TouchEvents.c](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/TouchEvents.c), [TouchEvents.h](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/TouchEvents.h)). These are readable with `CGEventGetIntegerValueField`/`CGEventGetDoubleValueField`, but `NSEvent(cgEvent:)` is the cleaner, shipping-proven path.
- **Consuming:** Apple's [`CGEventTapCallBack`](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback) contract says an active filter tap deletes an event by returning `NULL`. Hammerspoon applies this uniformly — its callback returns `NULL` for any event type, gestures included, when the user callback says "delete". Gesture events demonstrably flow *through* taps (see the interference bug below, which only makes sense if the window server routes gesture events via taps), so suppression is expected to work; this is the one point that deserves a 1-hour spike on current macOS before committing, since no Apple documentation guarantees it.

### Trade-offs

- **Undocumented:** Apple never promised type-29 events to taps; behavior could change in any release. (It has, however, been stable enough that Hammerspoon has shipped it for years.)
- **Known historical interference:** in the Mojave era, third-party apps tapping gesture-type events caused *intermittent system-wide breakage of all built-in two-finger gestures* (pinch, rotate, swipe-navigation). The developer of the Multitouch app diagnosed it: "It seems to be caused by 3rd party applications that listen to 'gesture' type events from an event tap", and the BetterTouchTool developer acknowledged a tap-handling bug in Mojave; both moved gesture recognition to the private multitouch framework as a result ([MacRumors thread](https://forums.macrumors.com/threads/macbook-pro-2018-multitouch-gestures-on-mojave-intermittently-going-out.2136385/)). No comparable wave of reports exists for recent macOS (Hammerspoon's gesture tap support postdates this and works), but it is the main historical risk on this route.
- **Depends on a user setting:** if "Zoom in or out" is disabled in System Settings > Trackpad > Scroll & Zoom, the system generates no magnify events at all (documented by Penc's README, same dependency for Route B).
- **Permissions:** same Accessibility/Input Monitoring (TCC) grant Riffle already needs for its existing tap and AX window manipulation. SIP does not need to be touched. Not App Store-able (irrelevant for Riffle).
- **Fit for Riffle:** best of all routes — Riffle already runs an event tap for Ctrl+Shift+scroll move, so this is `mask |= 1 << 29` plus a case in the existing callback, with consumption and modifier-gating identical to the move gesture.

## Route B — transparent overlay window (public API, Penc's approach)

[Penc](https://github.com/dgurkaynak/Penc) is an open-source "trackpad-oriented window manager" with *exactly* Riffle's interaction: activate (double-press Cmd), then two-finger swipe moves the window and pinch resizes it. It never touches gesture taps or private frameworks — its only pod dependencies are Silica and Sparkle. Instead, on activation it orders a borderless, full-screen `GestureOverlayWindow` onto every screen and makes it key ([Activation.swift](https://github.com/dgurkaynak/Penc/blob/master/Penc/activation/Activation.swift)). AppKit routes trackpad gesture events to that window, which simply overrides the responder method:

```swift
override func magnify(with event: NSEvent) {
    // event.magnification, event.phase — infer pinch angle from event touches
}
```

([GestureOverlayWindow.swift](https://github.com/dgurkaynak/Penc/blob/master/Penc/activation/GestureOverlayWindow.swift))

Because the overlay is the window receiving the gesture, the app underneath **never sees it** — capture and consumption both fall out of ordinary AppKit event routing, no undocumented behavior anywhere.

Trade-offs: Riffle would show/hide the overlay on Ctrl+Shift down/up (it already watches modifier state), which adds window-management plumbing; the overlay must be a non-activating panel so focus isn't stolen; while it is up it also intercepts clicks/scrolls (during a modifier-held Riffle gesture that is arguably desirable); and the same "Zoom in or out must be enabled" caveat applies since it consumes normal magnify NSEvents. Penc's README also documents that requirement explicitly ([README](https://github.com/dgurkaynak/Penc/blob/master/README.md)). This is the most robust route and is battle-tested in an app with Riffle's exact feature set.

## Route C — private MultitouchSupport.framework (raw touches)

- The private framework exposes `MTDeviceCreateList` plus per-device contact-frame callbacks delivering raw per-finger data (normalized position, velocity, pressure, ellipse axes, state machine) at frame rate. You then implement your own pinch recognizer (track distance between two contacts while Ctrl+Shift is down).
- Open-source wrappers: [Kyome22/OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) (Swift package, `AsyncStream` of `OMSTouchData` with position/pressure/axes/state, macOS 15+, **built-in trackpad only**, explicitly observation-only) and [mhuusko5/M5MultitouchSupport](https://github.com/mhuusko5/M5MultitouchSupport) (older Objective-C wrapper, multi-device via `MTDeviceCreateList`). Also [interface-club/open-multitouch-support](https://github.com/interface-club/open-multitouch-support) and various gists documenting the framework's structs.
- This is what the established gesture apps use: BetterTouchTool and Multitouch recognize gestures from the private framework rather than gesture-event taps (see MacRumors thread above), and Middle/MiddleDrag-class middle-click tools register MultitouchSupport callbacks for raw touch data ([MiddleDrag](https://github.com/NullPointerDepressiveDisorder/MiddleDrag); Middle was extracted from the Multitouch app — [Ryan Hanson's writeup](https://medium.com/ryan-hanson/middle-click-on-macos-3244baac43e2)). Swish is closed-source and doesn't document its internals, but its FAQ confirms it "needs to perform low-level system operations which prevent it from being sandboxed" ([swish site](https://highlyopinionated.co/swish/)).
- **Fatal flaw for this ticket:** the framework is a firehose of touch data, not an event pipeline — it **cannot consume anything**. The frontmost app still receives the native magnify events and will zoom while Riffle resizes, unless you *also* block them with an event tap (which is Route A again) or an overlay (Route B). It also has a track record of breaking across macOS/hardware generations (it's private), and the maintained Swift wrapper covers the built-in trackpad only — bad for Magic Trackpad users. Use only if Riffle someday needs gestures that produce no NSEvents (e.g. finger counts, taps); not needed for pinch.

## Route D — fallback: no pinch, second modifier + swipe for resize

If pinch capture proves flaky in practice: keep move on `Ctrl+Shift + two-finger swipe` and put resize on `Ctrl+Shift+Option + two-finger swipe` (or `Ctrl+Shift + swipe` with a mode toggle). Scroll-wheel events (`kCGEventScrollWheel`) are a fully public, documented tap type; observing and suppressing them is exactly what Riffle's move gesture already does, so this route has zero technical risk and no dependency on the trackpad zoom setting — at the cost of a less natural mapping than pinch.

## Recommendation for Riffle

1. **Spike Route A** (half a day): add `1 << 29` to the existing tap mask; on events of type 29, convert with `NSEvent(cgEvent:)`, gate on `.type == .magnify` + Ctrl+Shift flags, accumulate `.magnification`, return `nil` to consume. Verify on current macOS: (a) events arrive for built-in and Magic Trackpad, (b) returning `nil` actually stops the frontmost app from zooming, (c) native pinch in other apps is unaffected while Riffle's modifiers are *not* held.
2. If (b) or (c) fails, **implement Route B** (Penc-style non-activating overlay panel shown while Ctrl+Shift is held) — public API, guaranteed consumption, proven in Penc.
3. Handle the "Zoom in or out disabled" edge (both A and B): detect absence of magnify events / read the pref, and surface a hint in Riffle's UI.
4. Keep Route D in the back pocket; skip Route C entirely for pinch.

## Sources

- macOS SDK, `AppKit.framework/Headers/NSEvent.h`: `NSEventTypeGesture = 29`, `NSEventTypeMagnify = 30`, `NSEventMaskGesture = 1ULL << 29` (verified locally; see also [NSEvent.EventType.gesture](https://developer.apple.com/documentation/appkit/nsevent/eventtype/gesture) and [magnification](https://developer.apple.com/documentation/appkit/nsevent/1524304-magnification))
- Apple, [CGEventTapCallBack](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback) — active-filter taps delete an event by returning NULL; [CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate)
- Hammerspoon `hs.eventtap` — gesture events via session CGEventTap, NSEvent conversion, `.magnification`: [libeventtap_event.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap_event.m), [libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m), [docs: hs.eventtap.event](https://www.hammerspoon.org/docs/hs.eventtap.event.html)
- Calf Trail `TouchEvents` (vendored in Hammerspoon) — gesture CGEvent internals: subtype field 0x6E, magnify subtype 0x08, magnification field 0x71, phase field 0x84: [TouchEvents.c](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/TouchEvents.c), [TouchEvents.h](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/TouchEvents.h)
- MacRumors, [Mojave multitouch gestures intermittently breaking](https://forums.macrumors.com/threads/macbook-pro-2018-multitouch-gestures-on-mojave-intermittently-going-out.2136385/) — Multitouch dev (xryan) and BTT dev (Fuzzi) on gesture-event taps interfering with native gestures and the move to the private multitouch framework
- Penc — open-source trackpad window manager, overlay-window pinch capture: [repo](https://github.com/dgurkaynak/Penc), [GestureOverlayWindow.swift](https://github.com/dgurkaynak/Penc/blob/master/Penc/activation/GestureOverlayWindow.swift), [README (zoom-setting caveat)](https://github.com/dgurkaynak/Penc/blob/master/README.md)
- MultitouchSupport wrappers: [Kyome22/OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport), [mhuusko5/M5MultitouchSupport](https://github.com/mhuusko5/M5MultitouchSupport), [interface-club/open-multitouch-support](https://github.com/interface-club/open-multitouch-support)
- Middle-click tools on MultitouchSupport: [MiddleDrag](https://github.com/NullPointerDepressiveDisorder/MiddleDrag), [Ryan Hanson — Middle click on macOS](https://medium.com/ryan-hanson/middle-click-on-macos-3244baac43e2)
- Swish — [official site/FAQ](https://highlyopinionated.co/swish/) (not sandboxable, hence no App Store; internals undocumented)
