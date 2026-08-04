import CoreGraphics

/// The modifier keys that gate gestures.
nonisolated struct ModifierChord {
    enum Modifier: String, CaseIterable {
        case alternate = "Alt"
        case command = "Cmd"
        case control = "Ctrl"
        case shift = "Shift"
        case function = "Fn"

        var menuTitle: String { rawValue }

        var flag: CGEventFlags {
            switch self {
            case .alternate: .maskAlternate
            case .command: .maskCommand
            case .control: .maskControl
            case .shift: .maskShift
            case .function: .maskSecondaryFn
            }
        }
    }

    static let `default` = ModifierChord(modifiers: [.control, .shift])

    let flags: CGEventFlags

    // The modifiers a chord can be built from (spec: Alt / Cmd / Ctrl / Shift / Fn).
    // Everything else on an event's flags (caps lock, non-coalesced, device bits)
    // is ignored.
    private static let chordableModifiers: CGEventFlags = [
        .maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    init(flags: CGEventFlags) {
        self.flags = flags.intersection(Self.chordableModifiers)
    }

    init(modifiers: Set<Modifier>) {
        flags = modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            flags.insert(modifier.flag)
        }
    }

    func contains(_ modifier: Modifier) -> Bool {
        flags.contains(modifier.flag)
    }

    func toggling(_ modifier: Modifier) -> ModifierChord? {
        var modifiers = Set(Modifier.allCases.filter(contains))

        if modifiers == [modifier] {
            return nil
        }

        if modifiers.contains(modifier) {
            modifiers.remove(modifier)
        } else {
            modifiers.insert(modifier)
        }

        return ModifierChord(modifiers: modifiers)
    }

    /// Exact match: extra held modifiers prevent triggering.
    func matches(_ eventFlags: CGEventFlags) -> Bool {
        eventFlags.intersection(Self.chordableModifiers) == flags.intersection(Self.chordableModifiers)
    }
}
