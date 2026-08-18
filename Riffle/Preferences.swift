import CoreGraphics
import Foundation

final class Preferences {
    private enum Default {
        static let bringsTargetWindowToFront = true
        static let modifierChord = ModifierChord.default
        static let snapGesturesEnabled = true
    }

    private enum Key {
        static let bringsTargetWindowToFront = "bringsTargetWindowToFront"
        static let modifierChord = "modifierChord"

        static func snapGesture(_ gesture: SnapGesture) -> String {
            "snap.\(gesture.rawValue)"
        }
    }

    private let defaults: UserDefaults

    private(set) var bringsTargetWindowToFront: Bool
    private(set) var modifierChord: ModifierChord
    private(set) var enabledSnapGestures: Set<SnapGesture>

    nonisolated deinit {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var registered: [String: Any] = [
            Key.bringsTargetWindowToFront: Default.bringsTargetWindowToFront,
            Key.modifierChord: Int(Default.modifierChord.flags.rawValue),
        ]
        for gesture in SnapGesture.allCases {
            registered[Key.snapGesture(gesture)] = Default.snapGesturesEnabled
        }
        defaults.register(defaults: registered)

        bringsTargetWindowToFront = defaults.bool(forKey: Key.bringsTargetWindowToFront)
        let storedMask = UInt64(defaults.integer(forKey: Key.modifierChord))
        let storedChord = ModifierChord(flags: CGEventFlags(rawValue: storedMask))
        modifierChord = storedChord.flags.isEmpty ? .default : storedChord
        enabledSnapGestures = Set(SnapGesture.allCases.filter { gesture in
            defaults.bool(forKey: Key.snapGesture(gesture))
        })
    }

    func isSnapGestureEnabled(_ gesture: SnapGesture) -> Bool {
        enabledSnapGestures.contains(gesture)
    }

    func toggleSnapGesture(_ gesture: SnapGesture) {
        if enabledSnapGestures.contains(gesture) {
            enabledSnapGestures.remove(gesture)
        } else {
            enabledSnapGestures.insert(gesture)
        }
        defaults.set(enabledSnapGestures.contains(gesture), forKey: Key.snapGesture(gesture))
    }

    func toggleBringTargetWindowToFront() {
        bringsTargetWindowToFront.toggle()
        defaults.set(bringsTargetWindowToFront, forKey: Key.bringsTargetWindowToFront)
    }

    func resetToDefaults() {
        defaults.removeObject(forKey: Key.bringsTargetWindowToFront)
        defaults.removeObject(forKey: Key.modifierChord)
        for gesture in SnapGesture.allCases {
            defaults.removeObject(forKey: Key.snapGesture(gesture))
        }

        bringsTargetWindowToFront = Default.bringsTargetWindowToFront
        modifierChord = Default.modifierChord
        enabledSnapGestures = Set(SnapGesture.allCases)
    }

    @discardableResult
    func toggle(_ modifier: ModifierChord.Modifier) -> Bool {
        guard let updatedChord = modifierChord.toggling(modifier) else {
            return false
        }

        modifierChord = updatedChord
        defaults.set(Int(updatedChord.flags.rawValue), forKey: Key.modifierChord)

        return true
    }
}
