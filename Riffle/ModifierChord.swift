import CoreGraphics

/// The modifier keys that gate gestures.
struct ModifierChord {
    /// Hard-coded default until the configurable chord ships.
    static let `default` = ModifierChord(flags: [.maskControl, .maskShift])

    let flags: CGEventFlags

    // The modifiers a chord can be built from (spec: Alt / Cmd / Ctrl / Shift / Fn).
    // Everything else on an event's flags (caps lock, non-coalesced, device bits)
    // is ignored.
    private static let chordableModifiers: CGEventFlags = [
        .maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    /// Exact match: extra held modifiers prevent triggering.
    func matches(_ eventFlags: CGEventFlags) -> Bool {
        eventFlags.intersection(Self.chordableModifiers) == flags.intersection(Self.chordableModifiers)
    }
}
