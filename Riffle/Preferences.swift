import CoreGraphics
import Foundation

final class Preferences {
    private enum Default {
        static let bringsTargetWindowToFront = true
        static let modifierChord = ModifierChord.default
    }

    private enum Key {
        static let bringsTargetWindowToFront = "bringsTargetWindowToFront"
        static let modifierChord = "modifierChord"
    }

    private let defaults: UserDefaults

    private(set) var bringsTargetWindowToFront: Bool
    private(set) var modifierChord: ModifierChord

    nonisolated deinit {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Key.bringsTargetWindowToFront: Default.bringsTargetWindowToFront,
            Key.modifierChord: Int(Default.modifierChord.flags.rawValue),
        ])

        bringsTargetWindowToFront = defaults.bool(forKey: Key.bringsTargetWindowToFront)
        let storedMask = UInt64(defaults.integer(forKey: Key.modifierChord))
        let storedChord = ModifierChord(flags: CGEventFlags(rawValue: storedMask))
        modifierChord = storedChord.flags.isEmpty ? .default : storedChord
    }

    func toggleBringTargetWindowToFront() {
        bringsTargetWindowToFront.toggle()
        defaults.set(bringsTargetWindowToFront, forKey: Key.bringsTargetWindowToFront)
    }

    func resetToDefaults() {
        defaults.removeObject(forKey: Key.bringsTargetWindowToFront)
        defaults.removeObject(forKey: Key.modifierChord)

        bringsTargetWindowToFront = Default.bringsTargetWindowToFront
        modifierChord = Default.modifierChord
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
