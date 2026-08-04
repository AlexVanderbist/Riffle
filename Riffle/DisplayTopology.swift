import AppKit
import CoreGraphics

nonisolated struct DisplayTopology: Equatable {
    let displays: [CGRect]
    let mainDisplay: CGRect?

    @MainActor
    static var current: DisplayTopology {
        let activeDisplays = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, bounds: CGRect)? in
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let id = CGDirectDisplayID(displayNumber.uint32Value)

            return (id, CGDisplayBounds(id))
        }
        let mainDisplayID = CGMainDisplayID()

        return DisplayTopology(
            displays: activeDisplays.map(\.bounds),
            mainDisplay: activeDisplays.first(where: { $0.id == mainDisplayID })?.bounds
        )
    }
}
