# Research: moving and resizing other apps' windows via the Accessibility API

Resolves the research question in issue #4: how Riffle should find the window under the cursor and continuously move/resize it during a Ctrl+Shift gesture.

All claims below are sourced from the macOS SDK headers (`AXUIElement.h`, `AXAttributeConstants.h`, `AXActionConstants.h`, `AXValue.h` in `HIServices.framework`) and from two production implementations that do exactly this job: Easy Move+Resize (dmarcotte) and Rectangle (rxhanson), with Loop (MrKai77) as a third reference. File paths into those repos are given inline; full URLs are in Sources.

## Recommendation (TL;DR)

1. On gesture start, hit-test once with `AXUIElementCopyElementAtPosition` on the system-wide element (`AXUIElementCreateSystemWide()`), resolve the containing window via the element's `kAXWindowAttribute`, and **cache that `AXUIElementRef` plus its starting frame for the whole gesture**. Keep a `CGWindowListCopyWindowInfo`-based fallback for apps whose AX hit-testing is broken (Rectangle's approach).
2. During the gesture, accumulate deltas in local state and write the latest value with `AXUIElementSetAttributeValue(kAXPositionAttribute / kAXSizeAttribute)` wrapped in `AXValueCreate(kAXValueCGPointType/kAXValueCGSizeType, ...)` — **throttled to the display refresh interval**, never once per input event.
3. Before writing, if the target app's application element has `AXEnhancedUserInterface` set, disable it, write, then restore it (Rectangle's workaround; without it windows animate to wrong positions).
4. Guard resizes with `AXUIElementIsAttributeSettable(kAXSizeAttribute)` and treat clamped results as normal (apps enforce min/max sizes silently).
5. "Bring Window to Front" = `NSRunningApplication.activate` on the owning app + `AXUIElementPerformAction(window, kAXRaiseAction)` (exactly what Easy Move+Resize ships).
6. Permission flow: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` at launch, then poll `AXIsProcessTrusted()` until granted (Rectangle) and observe the `com.apple.accessibility.api` distributed notification plus re-check on failure to catch revocation.

## 1. Finding the window under the cursor

### Option A: AX hit test (primary)

`AXUIElementCopyElementAtPosition(systemWide, x, y, &element)` returns the deepest accessibility element at a screen position. The header is explicit that passing the system-wide element makes the test cross-application:

> "Note that if the system-wide accessibility object is passed in the `application` parameter, the position test is not restricted to a particular application." — `AXUIElement.h`

Errors to expect: `kAXErrorNoValue` (nothing at that position), `kAXErrorCannotComplete` (messaging to the target app failed — common with apps that implement AX poorly), `kAXErrorNotImplemented`.

**Walking up to the window:** you rarely need to walk `kAXParentAttribute` manually. Every element inside a window is required to expose the containing window directly:

> `kAXWindowAttribute`: "Required for any element that has an element of role kAXWindowRole somewhere in its parent chain." — `AXAttributeConstants.h`

Easy Move+Resize does exactly this (`EMRAppDelegate.m`, mouse-down branch): hit-test, check whether the returned element's role is already `kAXWindowRole` (`NSAccessibilityWindowRole`), otherwise read its `kAXWindowAttribute` to get the window element. A manual parent walk (checking `kAXRoleAttribute == kAXWindowRole` at each `kAXParentAttribute` hop) is only needed as a fallback for apps that don't implement `kAXWindowAttribute`.

### Option B: CGWindowList + AX matching (fallback)

Rectangle (`Rectangle/AccessibilityElement.swift`, `getWindowElementUnderCursor()`) treats the AX hit test as unreliable for some apps and uses a layered strategy:

1. (Optionally, per-app) system-wide AX hit test as above.
2. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` (`Rectangle/Utilities/WindowUtil.swift`), filtered to `kCGWindowLayer < 21` (below Notification Center) and excluding `Dock`/`WindowManager` processes, first window whose `kCGWindowBounds` contains the cursor. The winning `kCGWindowOwnerPID` is turned into an app AX element (`AXUIElementCreateApplication(pid)`), and its `kAXWindowsAttribute` array is matched to the CGWindow by **window ID** using the private `_AXUIElementGetWindow(element, &windowId)` (`Rectangle/Utilities/AXExtension.swift`), falling back to frame equality.
3. AX hit test again (if not tried first).
4. Last resort: the frontmost app's `kAXWindowsAttribute`, smallest window whose frame contains the cursor (for when the window server isn't vending window info).

**For Riffle:** start with Option A only — it is one call, needs no private API, and Easy Move+Resize (the closest product to Riffle) ships with it alone. Add Rectangle's window-list fallback if testing surfaces apps where the hit test fails (Rectangle added each layer in response to real bugs, e.g. Stage Manager and window-server issues). Note `_AXUIElementGetWindow` is private API — fine for a non-MAS app, not App Store safe.

CGWindowList ordering matters: the list is front-to-back, so "first match containing the point" is the visually topmost window; a plain AX hit test also resolves the topmost element. Both approaches agree in the common case.

## 2. Caching the window reference for the gesture

Do the hit test **once, on gesture start**, and cache:

- the window `AXUIElementRef` (CFRetain it / hold it in a Swift property),
- the window's starting `kAXPositionAttribute` (and `kAXSizeAttribute` for pinch),
- the owning `pid`/`NSRunningApplication` (via `AXUIElementGetPid`) for the enhanced-UI toggle, app exclusion lists, and activation.

Easy Move+Resize does exactly this: on modifier+mouse-down it stores the window and its top-left in an `EMRMoveResize` singleton; every subsequent drag event only adds `kCGMouseEventDeltaX/Y` to the cached position and writes — no per-event hit test, no per-event attribute reads. Per-event hit testing would add a synchronous cross-process round trip per input event and would also mis-target once the window has moved out from under the cursor mid-gesture.

`AXUIElementRef`s stay valid while the window exists; a destroyed window yields `kAXErrorInvalidUIElement` on the next call, which should silently end the gesture. Clear the cache on gesture end (Ctrl+Shift released / gesture phase ended).

## 3. Setting position and size

Values are structs boxed with `AXValueCreate`:

```c
CGPoint p = ...;
AXValueRef v = AXValueCreate(kAXValueCGPointType, &p);
AXUIElementSetAttributeValue(window, kAXPositionAttribute, v);
CFRelease(v);
// same with kAXValueCGSizeType + kAXSizeAttribute
```

Key mechanics:

- **Position and size are separate writes; there is no frame attribute.** Rectangle: "The Accessibility API only allows size & position adjustments individually." (`AccessibilityElement.swift`, `setFrame`).
- **Order matters when both change.** For a one-shot frame set (e.g. across displays), Rectangle sets size → position → size, "since macOS will enforce sizes that fit on the current display". Loop's `Window.setFrame` does the same optional size-first, then position, then size. For Riffle's incremental gestures this mostly reduces to: move gesture writes position only; pinch writes size, plus position first when the anchor requires the top-left to shift (Easy Move+Resize writes position before size, and only when resizing from the left/bottom edges).
- Coordinates for `kAXPositionAttribute` are the window's **top-left corner in top-left-origin global screen coordinates** (see §7).
- `kAXErrorSuccess` does not guarantee the requested value was applied — apps clamp (see §8, non-resizable windows). Don't build logic that assumes write == result; re-read the attribute if the actual value matters.

## 4. Performance: rapid per-event writes need throttling

Every `AXUIElementSetAttributeValue` is a **synchronous Mach IPC round trip into the target app's main thread**, so cost is dictated by the target app (Electron/Chrome are notoriously slow — Rectangle issue #912 "Repositioning and resizing windows is super slow for Chrome"). Trackpad gestures deliver events far faster than slow apps can service them. Both reference implementations throttle:

- Easy Move+Resize accumulates deltas on every event but only calls `AXUIElementSetAttributeValue` when at least one display refresh interval has elapsed, with the interval derived from `NSScreen.minimumRefreshInterval` across all screens (1/60 s floor). Code comment: "actually applying the change is expensive, so only do it every kMoveFilterInterval seconds" (`EMRAppDelegate.m`).
- The write applies the **latest accumulated value**, not a queue of intermediate ones — that is the coalescing. State advances every event; IPC happens at ≤ refresh rate.

Recommended pattern for Riffle: accumulate gesture deltas into a target frame; a write is in flight or the refresh interval hasn't elapsed → just update the target; otherwise write the current target. Since ProMotion trackpads/gestures can outrun even 120 Hz, this alone removes most jank. Two further mitigations from primary sources:

- `AXUIElementSetMessagingTimeout(element, seconds)` (`AXUIElement.h`) lowers the per-element (or process-global, via the system-wide element) AX messaging timeout so a hung target app fails fast with `kAXErrorCannotComplete` instead of stalling your gesture thread. Set a small timeout (Rectangle-class apps use ~1 s or less) on the cached window element.
- If Riffle consumes gestures via a `CGEventTap`, a slow callback gets the tap disabled by the system (`kCGEventTapDisabledByTimeout`). Easy Move+Resize explicitly re-enables the tap when that event type arrives: "need to re-enable our eventTap (We got disabled. Usually happens on a slow resizing app)". Better: never do AX writes synchronously inside the tap callback; hop to another queue/runloop and let the tap return immediately.

Also: do the writes off the main thread if Riffle draws any UI of its own, but keep all AX calls for one gesture on a single serial queue — interleaved writes to the same window from multiple threads produce out-of-order frames.

## 5. Permission flow (AXIsProcessTrustedWithOptions) and revocation

- One-shot prompt at launch:

  ```swift
  let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
  let trusted = AXIsProcessTrustedWithOptions(opts)
  ```

  Header: "Prompting occurs asynchronously and does not affect the return value" — i.e. the call returns `false` immediately while the system shows the "grant access in System Settings" dialog. (`AXUIElement.h`; Easy Move+Resize does exactly this and exits, relying on next launch.)
- **Better UX (Rectangle):** if `AXIsProcessTrusted()` is false, show an onboarding window and poll `AXIsProcessTrusted()` on a 0.3 s timer; when it flips to true, tear down the onboarding and start the event tap — no relaunch needed (`Rectangle/AccessibilityAuthorization/AccessibilityAuthorization.swift`). Note: the *prompt* variant should be called once, not polled, or the dialog re-triggers.
- **Detecting revocation:** there is no public callback. Two complementary signals:
  1. Observe `DistributedNotificationCenter` name `"com.apple.accessibility.api"` — it fires when accessibility settings change (for any app, so re-check `AXIsProcessTrusted()` in the handler, and expect a small propagation delay).
  2. Treat AX call failures (`kAXErrorCannotComplete`/`kAXErrorAPIDisabled` patterns) during a gesture as a trigger to re-check trust. Caveat from Apple's forums: when permission is removed via MDM configuration profile (as opposed to the user toggling System Settings), `AXIsProcessTrusted` can keep returning true while calls hang — the messaging timeout from §4 is the backstop.
- macOS identifies the trusted binary by code signature/path; rebuilding an unsigned dev build can silently invalidate the grant (toggle off/on in System Settings). Sign with a stable identity during development.

## 6. Bring Window to Front

Easy Move+Resize's shipped "bring window to front" option is the exact recipe:

```objc
[app activateWithOptions:NSApplicationActivateIgnoringOtherApps]; // NSRunningApplication
AXUIElementPerformAction(clickedWindow, kAXRaiseAction);
```

- `kAXRaiseAction` (`AXActionConstants.h`, `CFSTR("AXRaise")`) raises that specific window within its app; activation makes the app frontmost. You need both: activate alone brings forward a different (key) window of that app; raise alone brings the window above its siblings but doesn't give the app focus.
- `AXUIElementPerformAction` may legitimately return `kAXErrorCannotComplete` on slow apps and can be retried (header discussion in `AXUIElement.h`).
- On macOS 14+ `activate(options:)`'s `.activateIgnoringOtherApps` is deprecated under cooperative activation; plain `activate()` from a background utility still works for this use case (Loop, current release, still calls `runningApplication.activate(options: .activateIgnoringOtherApps)` and additionally pokes private SkyLight `makeKeyWindow` for stubborn cases — don't start there).

## 7. Coordinate systems

- **AX is top-left-origin.** `kAXPositionAttribute`: "The global screen position of the top-left corner of an element. ... 0,0 is the top-left corner of the screen that displays the menu bar. The value of the vertical axis increases downward." (`AXAttributeConstants.h`).
- **AppKit is bottom-left-origin** (`NSEvent.mouseLocation`, `NSScreen.frame`). Convert with a flip against the *primary* screen (`NSScreen.screens[0]`, the one with the menu bar): `axY = screens[0].frame.maxY - cocoaY` (for a point; for a rect also subtract height). Rectangle does this with a `screenFlipped` extension before hit-testing (`NSEvent.mouseLocation.screenFlipped`).
- **CGEventTap coordinates need no conversion**: `CGEventGetLocation` is already top-left-origin global, which is why Easy Move+Resize feeds it straight into `AXUIElementCopyElementAtPosition` and adds `kCGMouseEventDeltaX/Y` directly to the AX position. If Riffle reads the cursor from the event tap, it can stay in AX coordinates end to end and only flip when it touches `NSScreen`/`NSEvent` APIs.
- **Multi-display:** the flip is always against the primary screen, not the screen under the cursor. Displays left of or above the primary produce negative AX coordinates; that's normal. Mixed-refresh-rate setups are why Easy Move+Resize computes its throttle from the minimum refresh interval across all screens.

## 8. Gotchas and mitigations

| Gotcha | What happens | Mitigation |
|---|---|---|
| `AXEnhancedUserInterface` ("enhanced user interface") | When VoiceOver or other AX clients set this app-element attribute, position writes misbehave — windows animate oddly and "end up in incorrect position" (documented for Chrome in Phoenix PR #310; Rectangle logs "AXEnhancedUserInterface was enabled, will disable before resizing"). | Rectangle's pattern: read `AXEnhancedUserInterface` on the app element, set it to false, do the position/size writes, restore it afterward (Rectangle even offers disable-only and disable-until-app-switch modes because re-enabling can retrigger the problem mid-session). For a gesture, disable once at gesture start and restore at gesture end, not per write. |
| Non-resizable windows / size constraints | `kAXSizeAttribute` is "Writable? Generally no. However, some elements that can be resized by the user through direct manipulation (like windows) should offer a writable size attribute" (header). Fixed-size windows (alerts, some utility panels) reject or ignore size writes; resizable windows silently clamp to their min/max content size and still return `kAXErrorSuccess`. | Check `AXUIElementIsAttributeSettable(window, kAXSizeAttribute, &settable)` at gesture start; skip/decline the pinch gesture if not settable (Loop models this as an `isResizable` flag and skips `setSize`). Accept clamping: track your *intended* size separately from the actual one so the gesture stays continuous when the user pinches back out past the clamp point. |
| Windows on other Spaces | The AX API only exposes windows on currently visible Spaces: "only those window IDs that are present on the currently visible spaces will be findable" (Hammerspoon `hs._asm.spaces`); manipulating off-Space windows requires private SkyLight APIs (yabai's approach). | Non-issue for Riffle's core gesture — the window under the cursor is by definition on the active Space. Just don't build features that assume `kAXWindowsAttribute` enumerates everything (it also omits some full-screen windows). |
| Slow target apps stall input | Synchronous AX IPC into e.g. Chrome/Electron blocks the caller; a slow `CGEventTap` callback gets disabled by the OS with `kCGEventTapDisabledByTimeout`. | Throttle to refresh interval + coalesce (§4); `AXUIElementSetMessagingTimeout` on the cached element; handle `kCGEventTapDisabledByTimeout`/`ByUserInput` by re-enabling the tap (Easy Move+Resize does); do AX writes outside the tap callback. |
| Hit test returns wrong/no element | Some apps mis-implement AX hit-testing; window server occasionally vends no info (Rectangle #640); Stage Manager strip windows need special-casing. | Layered lookup (§1 Option B); treat `kAXErrorNoValue`/`kAXErrorCannotComplete` as "no gesture", never crash. |
| Element under cursor isn't in a window | Hit test can land on the desktop, Dock, or menu bar; `kAXWindowAttribute` then fails. | Require a resolved window element before starting the gesture; optionally filter by window `kAXSubroleAttribute == kAXStandardWindowSubrole` to skip panels/sheets, and exclude own/Dock/WindowManager processes (Rectangle filters `level < 21` and those process names). |
| Permission revoked mid-run | AX calls start failing; with MDM-profile revocation `AXIsProcessTrusted` may even stay true while calls hang. | §5: distributed notification + re-check on failure + messaging timeout; degrade to a "permission needed" menu-bar state instead of dead gestures. |
| Coordinate flips | Mixing `NSEvent.mouseLocation` (bottom-left) with AX (top-left) puts windows on the wrong display/half of the screen; worst on multi-display with negative coordinates. | Stay in top-left CG/AX coordinates throughout the gesture pipeline; flip only at AppKit boundaries, always against `NSScreen.screens[0]` (§7). |

## Sources

Apple SDK headers (macOS SDK, `ApplicationServices.framework/Frameworks/HIServices.framework/Headers/`): `AXUIElement.h` (AXUIElementCopyElementAtPosition, AXUIElementCreateSystemWide, AXUIElementSetAttributeValue, AXUIElementIsAttributeSettable, AXUIElementPerformAction, AXUIElementSetMessagingTimeout, AXIsProcessTrustedWithOptions), `AXAttributeConstants.h` (kAXPositionAttribute, kAXSizeAttribute, kAXWindowAttribute, kAXWindowsAttribute), `AXActionConstants.h` (kAXRaiseAction), `AXValue.h` (AXValueCreate). Online mirrors:

- https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
- https://developer.apple.com/documentation/applicationservices/1459374-axuielementsetattributevalue
- https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrustedwithoptions
- https://developer.apple.com/documentation/applicationservices/kaxpositionattribute
- https://developer.apple.com/documentation/appkit/nsrunningapplication/1528725-activate

Implementations:

- Easy Move+Resize (dmarcotte) — `EMRAppDelegate.m` (event tap, hit test, caching, refresh-interval throttling, kAXRaiseAction + activate, AXIsProcessTrustedWithOptions): https://github.com/dmarcotte/easy-move-resize/blob/master/easy-move-resize/EMRAppDelegate.m
- Rectangle (rxhanson) — `AccessibilityElement.swift` (setFrame order, AXEnhancedUserInterface disable/restore, getWindowElementUnderCursor fallbacks): https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift
- Rectangle — `Utilities/WindowUtil.swift` (CGWindowListCopyWindowInfo filtering): https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/WindowUtil.swift
- Rectangle — `Utilities/AXExtension.swift` (`_AXUIElementGetWindow`): https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/AXExtension.swift
- Rectangle — `AccessibilityAuthorization/AccessibilityAuthorization.swift` (poll AXIsProcessTrusted): https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityAuthorization/AccessibilityAuthorization.swift
- Rectangle issue #912 — Chrome AX writes are slow: https://github.com/rxhanson/Rectangle/issues/912
- Phoenix PR #310 — AXEnhancedUserInterface causes wrong positions (Chrome): https://github.com/kasper/phoenix/pull/310
- Loop (MrKai77) — `Window.swift` (setFrame order, enhancedUserInterface toggle, focus/raise): https://github.com/MrKai77/Loop/blob/main/Loop/Window%20Management/Window/Window.swift
- Hammerspoon `hs._asm.spaces` — AX only sees windows on visible Spaces: https://github.com/asmagill/hs._asm.spaces
- Accessibility permission mechanics and prompt flow: https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html
- Apple Developer Forums — TCC Accessibility revocation edge cases (profiles, hangs): https://developer.apple.com/forums/thread/703188
