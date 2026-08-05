import CoreGraphics
import Foundation

final class Preferences {
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
            Key.bringsTargetWindowToFront: true,
            Key.modifierChord: Int(ModifierChord.default.flags.rawValue),
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
