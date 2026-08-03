# Research: status bar app shell — menu, login item, settings persistence

Resolves issue #5. Researched against Apple documentation and real open-source menu bar apps (Rectangle, Easy Move+Resize, Ice, Stats). All claims cited in [Sources](#sources).

## Recommendation (TL;DR)

Build the shell on **AppKit: `NSStatusItem` + `NSMenu` with an `NSMenuDelegate`**, not SwiftUI's `MenuBarExtra`. Use a plain `NSApplicationDelegate` entry point (no SwiftUI scenes — there is no window UI to justify them). Configure the app as a menu-bar-only accessory via `LSUIElement`, **turn the App Sandbox off** (the fresh Xcode template has it on via `ENABLE_APP_SANDBOX = YES`), implement Launch at Login with `SMAppService.mainApp`, and persist everything in `UserDefaults.standard` behind a small `Preferences` type — no `@AppStorage`, no KVO gymnastics needed.

This is exactly the architecture of Easy Move+Resize (whose menu is item-for-item the menu Riffle needs) and, minus the nib, of Rectangle, Ice, and Stats. None of the serious window-manager menu bar apps use `MenuBarExtra`.

## MenuBarExtra vs NSStatusItem + NSMenu

### What MenuBarExtra gives you

`MenuBarExtra` (macOS 13+) is a SwiftUI scene that renders a persistent control in the menu bar. The default `.menu` style renders SwiftUI `Button`/`Toggle`/`Divider`/`Menu` content as a real dropdown menu; `Toggle` produces a checkmark item, and nested `Menu` produces a submenu. It also supports an `isInserted` binding to show/hide the item, and Apple's docs note that for menu-bar-only apps you still set `LSUIElement` yourself.

So checkmark toggles and the "Re-enable for ▸" submenu are *expressible* in MenuBarExtra. The friction is everywhere else:

- **No "menu is about to open" hook.** AppKit gives you `NSMenuDelegate.menuNeedsUpdate(_:)`, which is "invoked when a menu is about to be displayed at the start of a tracking session" — the exact right moment to compute "Disable for \<frontmost app\>" and rebuild the re-enable submenu. MenuBarExtra has no equivalent; content is state-driven, so the dynamic title has to be kept fresh *continuously* (e.g. observing `NSWorkspace.didActivateApplicationNotification` and republishing `@Published` state on every app switch) instead of computed lazily once per menu open.
- **No access to the underlying machinery.** There is no first-party API to get or set the menu presentation state, programmatically dismiss it, disable the item, or reach the `NSStatusItem`/`NSWindow` underneath. A whole ecosystem of workaround libraries exists for this (MenuBarExtraAccess, fluid-menu-bar-extra), which is a strong signal: the moment you need anything dynamic or stateful you end up depending on third-party shims around AppKit anyway.
- **Polish gaps.** No right-click menu on the status item; the `.window` style (not needed here, but for the record) doesn't fade out on dismissal or persist selection state like a native menu (fluid-menu-bar-extra README, Cindori).
- **What the field does.** Rectangle, Easy Move+Resize, Ice, and Stats — all menu-bar utilities with dynamic menus — are built on `NSStatusItem`. Multi's engineering write-up on status items concludes the same: `NSStatusItem` can be bent to arbitrary needs; `MenuBarExtra` can't.

### What NSStatusItem + NSMenu gives you

Everything on Riffle's menu list is a first-class AppKit feature:

- **Checkmark toggles**: `NSMenuItem.state = .on/.off`. Set `menu.autoenablesItems = false` and manage `isEnabled` manually (Easy Move+Resize does both).
- **Dynamic "Disable for \<frontmost app\>"**: implement `menuNeedsUpdate(_:)`; per Apple's docs the delegate may add, remove, or modify items there, and item validation runs after it returns. Read `NSWorkspace.shared.frontmostApplication`, set the item's title to `"Disable for \(app.localizedName)"` and stash the bundle id in `representedObject`.
- **"Re-enable for ▸" submenu rebuilt from a persisted list**: rebuild in the same `menuNeedsUpdate` pass. Easy Move+Resize's `reconstructDisabledAppsSubmenu` is the template: create a fresh `NSMenu`, add one item per persisted `bundleId → localizedName` entry with the bundle id as `representedObject`, and set the parent item `isEnabled = !disabledApps.isEmpty`.
- **Modifier multi-select (Alt/Cmd/Ctrl/Shift/Fn)**: five checkmark items sharing one action; toggle the sender's `state`, persist, and recompute the cached `CGEventFlags` mask (Easy Move+Resize's `modifierToggle:`).

Easy Move+Resize's `EMRAppDelegate.m` implements literally this menu — Disabled, five modifier checkmarks, Bring Window to Front, Resize Only, "Disable for %@" (title updated via `setMostRecentApp`), a disabled-apps submenu (`representedObject` = bundle id, disabled when empty), and Reset to Defaults — in ~150 lines of menu code. The one improvement for Riffle: compute the "Disable for" title in `menuNeedsUpdate` from the frontmost app instead of eagerly on drag, so it always tracks the frontmost app with zero background bookkeeping.

**Verdict**: `NSStatusItem` + `NSMenu` + `NSMenuDelegate`. MenuBarExtra buys nothing here (Riffle has no SwiftUI views to host) and costs the exact feature the menu is built around: lazy per-open dynamic content.

## Accessory (menu-bar-only) app configuration

- Set `LSUIElement` = `YES` — Xcode display name "Application is agent (UIElement)". The app then "runs in the background and doesn't appear in the Dock" (and gets no app menu bar of its own). The template uses `GENERATE_INFOPLIST_FILE = YES`, so add it as the `INFOPLIST_KEY_LSUIElement = YES` build setting (Target → Info tab) rather than a physical Info.plist. Easy Move+Resize and Rectangle both ship `LSUIElement` = true.
- The runtime equivalent is `NSApp.setActivationPolicy(.accessory)` (macOS 10.9+ allows switching to any policy at runtime). Riffle is *always* menu-bar-only, so prefer the static plist key; the runtime call is only worth it for apps that toggle a Dock presence.

## App Sandbox must be OFF

Riffle moves and resizes **other apps'** windows through `AXUIElementCopyElementAtPosition` / `AXUIElementSetAttributeValue`. That is exactly what the sandbox forbids:

- Apple (DTS, Quinn "The Eskimo!"), asked whether a sandboxed app can call `AXUIElementCreateApplication(pid)`: **"No."** Sandboxed apps may monitor input events, but "sandboxed apps do not have access to all the Accessibility APIs" — specifically not the ones that inspect and control other applications. This is also why apps like Rectangle are not on the Mac App Store.
- Rectangle ships an **empty entitlements file** (`Rectangle.entitlements` is an empty `<dict/>`) — no sandbox. Easy Move+Resize has no entitlements at all.

Even with the sandbox off, the user must still grant the app **Accessibility permission** (System Settings → Privacy & Security → Accessibility). Prompt for it with `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` at launch, as Easy Move+Resize does. Note the TCC grant is tied to the signed bundle identity; if permission wedges during development, `tccutil reset Accessibility <bundle-id>` clears it (Rectangle's README documents the same reset).

### Changes to the fresh Xcode template (checklist)

The current `Riffle.xcodeproj` (fresh SwiftUI template, deployment target 26.2, no `.entitlements` file — modern Xcode expresses default capabilities as build settings):

1. **`ENABLE_APP_SANDBOX = YES` → `NO`** (both Debug and Release; or remove the App Sandbox capability in Signing & Capabilities). `ENABLE_USER_SELECTED_FILES = readonly` becomes moot and can go too.
2. **Add `INFOPLIST_KEY_LSUIElement = YES`** (template has `GENERATE_INFOPLIST_FILE = YES`).
3. **Replace the SwiftUI entry point**: delete `RiffleApp` (`@main App` with `WindowGroup`) and `ContentView`; add `@main final class AppDelegate: NSObject, NSApplicationDelegate` that creates the `NSStatusItem`, builds the `NSMenu` in code (no nib), and installs the event tap in `applicationDidFinishLaunching`.
4. **Signing / hardened runtime**: keep `CODE_SIGN_STYLE = Automatic`. The template does not enable the Hardened Runtime, and for a personal, locally built app none is needed — hardened runtime only becomes relevant for Developer ID notarization when distributing, and it does not restrict AX control of other apps (that's governed by the TCC Accessibility grant, not the runtime). The only practical concern: every re-sign with a different identity can invalidate the Accessibility grant (see `tccutil` above), so a stable development certificate is worth having.

## Launch at Login: SMAppService.mainApp

`SMAppService` (macOS 13+, ServiceManagement framework) replaces the old `SMLoginItemSetEnabled` + helper-bundle dance. For a login item that is just the app itself:

- `SMAppService.mainApp.register()` / `.unregister()` — both throwing.
- `SMAppService.mainApp.status` — `.enabled`, `.notRegistered`, `.requiresApproval`, `.notFound`. Drive the menu checkmark from `status == .enabled`, computed in `menuNeedsUpdate` so it also reflects changes the user made directly in System Settings → General → Login Items.
- If status is `.requiresApproval`, `SMAppService.openSystemSettingsLoginItems()` deep-links the user to the approval pane.

Rectangle's `LaunchOnLogin.swift` is the reference implementation: `isEnabled` getter is `SMAppService.mainApp.status == .enabled`; setter registers/unregisters in a do/catch (it defensively unregisters before re-registering).

## Settings persistence: UserDefaults

Store in `UserDefaults.standard` (Rectangle persists everything in `NSUserDefaults` at `~/Library/Preferences/<bundle-id>.plist`):

| Setting | Representation |
|---|---|
| Modifier set (Alt/Cmd/Ctrl/Shift/Fn) | array of strings (or raw `UInt64` `CGEventFlags` mask); cache the computed mask in memory for the event tap hot path |
| Disabled / Bring to Front / Resize Only | `Bool` keys |
| Disabled apps | `[String: String]` dictionary, `bundleId → localizedName` — the name is needed to render the "Re-enable for ▸" submenu titles (Easy Move+Resize stores exactly this shape) |

Practical guidance:

- **Seed defaults with `register(defaults:)`** so first launch has a sensible modifier combo; **Reset to Defaults** = remove the known keys (or `removePersistentDomain(forName:)`) and re-read, as Easy Move+Resize's `setToDefaults` + `initMenuItems` does.
- **`@AppStorage` is the wrong tool here.** It is "a property wrapper type that reflects a value from UserDefaults and invalidates a view on a change" — it exists to refresh SwiftUI *views*, and Riffle has none. With no settings window, there is exactly one writer (the menu's action methods), so the simplest correct design is a small `Preferences` class wrapping `UserDefaults`: menu actions write through it and synchronously update the in-memory state the event tap reads (Easy Move+Resize refreshes its cached `keyModifierFlags` in each toggle action). Menu checkmarks don't need observation at all — they're recomputed from `Preferences` in `menuNeedsUpdate` each time the menu opens.
- **If observation is ever needed** (e.g. reacting to `defaults write` from a terminal): `UserDefaults.didChangeNotification` fires only for changes made *by the same process* (posted on the thread that made the change); changes from other processes require KVO on the specific keys. Neither is required for v1.

## Concrete recommendation for Riffle

1. AppKit shell: `@main` `NSApplicationDelegate`; `NSStatusItem` from `NSStatusBar.system` with a template image; one code-built `NSMenu` with `autoenablesItems = false` and the app delegate as `NSMenuDelegate`.
2. In `menuNeedsUpdate`: set checkmark states from `Preferences`; retitle/enable "Disable for \<frontmost app\>" from `NSWorkspace.shared.frontmostApplication` (disable the item when frontmost is Riffle itself or nil); rebuild "Re-enable for ▸" from the persisted dictionary, disabling it when empty; set the Launch at Login checkmark from `SMAppService.mainApp.status == .enabled`.
3. Template surgery: sandbox off, `INFOPLIST_KEY_LSUIElement = YES`, SwiftUI files deleted, automatic signing kept, no hardened runtime.
4. `AXIsProcessTrustedWithOptions` prompt at launch; keep running (rather than `exit(1)`) and poll or re-check so the user can grant permission without a relaunch — an improvement over Easy Move+Resize.
5. Launch at Login via `SMAppService.mainApp`; Exit item calls `NSApp.terminate(nil)`.
6. `Preferences` type over `UserDefaults.standard` with `register(defaults:)`, the table of keys above, and a reset method.

## Sources

Apple documentation:
- MenuBarExtra — https://developer.apple.com/documentation/swiftui/menubarextra
- NSMenuDelegate.menuNeedsUpdate(_:) — https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:)
- SMAppService — https://developer.apple.com/documentation/servicemanagement/smappservice
- LSUIElement — https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement
- NSApplication.setActivationPolicy(_:) — https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:)
- Protecting user data with App Sandbox — https://developer.apple.com/documentation/security/app_sandbox/protecting_user_data_with_app_sandbox
- Configuring the macOS App Sandbox — https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- UserDefaults.didChangeNotification — https://developer.apple.com/documentation/foundation/userdefaults/didchangenotification
- AppStorage — https://developer.apple.com/documentation/swiftui/appstorage
- Apple DTS (Quinn) on sandboxed apps and AX APIs — https://developer.apple.com/forums/thread/756130

Open-source apps and field reports:
- Easy Move+Resize (`EMRAppDelegate.m`: full NSStatusItem/NSMenu blueprint, AX prompt, disabled-apps submenu) — https://github.com/dmarcotte/easy-move-resize
- Rectangle (`LaunchOnLogin.swift`: SMAppService.mainApp; empty `Rectangle.entitlements`; `LSUIElement` in Info.plist; UserDefaults persistence; tccutil reset) — https://github.com/rxhanson/Rectangle
- Ice (NSStatusItem-based) — https://github.com/jordanbaird/Ice
- Stats (NSStatusItem-based) — https://github.com/exelban/stats
- MenuBarExtraAccess (documents MenuBarExtra's missing first-party APIs) — https://github.com/orchetect/MenuBarExtraAccess
- fluid-menu-bar-extra (MenuBarExtra window-style polish gaps) — https://github.com/lfroms/fluid-menu-bar-extra
- Multi: "Pushing the limits of NSStatusItem" — https://multi.app/blog/pushing-the-limits-nsstatusitem
- Cindori: "Hands-on: building a Menu Bar experience with SwiftUI" — https://cindori.com/developer/hands-on-menu-bar
- Nil Coalescing: "Build a macOS menu bar utility in SwiftUI" — https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/
