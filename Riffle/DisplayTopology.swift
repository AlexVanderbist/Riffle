import AppKit
import CoreGraphics

nonisolated struct DisplayTopology: Equatable {
    let displays: [CGRect]
    let mainDisplay: CGRect?
    /// Parallel to `displays`: the height of the menu bar strip at the top of
    /// each display, 0 when that display shows none. macOS never lets a window
    /// origin land above it, so neither may a Move Gesture.
    let menuBarHeights: [CGFloat]

    init(displays: [CGRect], mainDisplay: CGRect?, menuBarHeights: [CGFloat]? = nil) {
        self.displays = displays
        self.mainDisplay = mainDisplay
        self.menuBarHeights = menuBarHeights ?? Array(repeating: 0, count: displays.count)
    }

    @MainActor
    static var current: DisplayTopology {
        let activeDisplays = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, bounds: CGRect, menuBarHeight: CGFloat)? in
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let id = CGDirectDisplayID(displayNumber.uint32Value)
            // AppKit frames are bottom-left origin, so the menu bar is the gap
            // between the top of the frame and the top of the visible frame.
            let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)

            return (id, CGDisplayBounds(id), menuBarHeight)
        }
        let mainDisplayID = CGMainDisplayID()

        return DisplayTopology(
            displays: activeDisplays.map(\.bounds),
            mainDisplay: activeDisplays.first(where: { $0.id == mainDisplayID })?.bounds,
            menuBarHeights: activeDisplays.map(\.menuBarHeight)
        )
    }
}
