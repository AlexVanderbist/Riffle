/// Pure state machine deciding which gesture owns the current trackpad interaction.
///
/// The first chorded Move or Resize Gesture owns the interaction until finger
/// lift. Captured scroll momentum and competing gesture frames are consumed
/// without changing that owner.
struct GestureLatch {
    struct MagnifyPhase: OptionSet {
        let rawValue: UInt

        static let none = MagnifyPhase([])
        static let began = MagnifyPhase(rawValue: 1)
        static let changed = MagnifyPhase(rawValue: 4)
        static let ended = MagnifyPhase(rawValue: 8)
        static let cancelled = MagnifyPhase(rawValue: 16)
    }

    /// Raw values of `CGEventField.scrollWheelEventScrollPhase`.
    enum ScrollPhase {
        static let none: Int64 = 0
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
        static let cancelled: Int64 = 8
        static let mayBegin: Int64 = 128
    }

    /// Raw values of `CGEventField.scrollWheelEventMomentumPhase`.
    enum MomentumPhase {
        static let none: Int64 = 0
        static let begin: Int64 = 1
        static let continuing: Int64 = 2
        static let end: Int64 = 3
    }

    enum ScrollAction: Equatable {
        /// Not ours; deliver the event to the app beneath untouched.
        case passThrough
        /// Consume; start a move on the window under the cursor, then apply
        /// this event's deltas.
        case beginMove
        /// Consume; apply this event's deltas to the target frame.
        case applyMove
        /// Consume; fingers lifted — freeze the window at the last applied frame.
        case liftFingers
        /// Consume silently (momentum frames, stray phases).
        case discard
        /// Consume; the momentum tail is over — release the latch.
        case finishStream
    }

    enum MagnifyAction: Equatable {
        case passThrough
        case beginResize
        case applyResize
        case liftFingers
        case discard
    }

    private(set) var isCapturingScroll = false
    private(set) var isCapturingMagnify = false

    private enum Owner {
        case move
        case resize
    }

    private var owner: Owner?

    mutating func handleScroll(
        isContinuous: Bool,
        scrollPhase: Int64,
        momentumPhase: Int64,
        chordMatches: Bool
    ) -> ScrollAction {
        // Line-based mouse wheels are never ours, even mid-capture.
        guard isContinuous else { return .passThrough }

        // Began is the only place the capture decision is made.
        if scrollPhase == ScrollPhase.began {
            isCapturingScroll = chordMatches
            guard isCapturingScroll else { return .passThrough }
            guard owner != .resize else { return .discard }
            owner = .move
            return .beginMove
        }

        guard isCapturingScroll else { return .passThrough }

        if momentumPhase == MomentumPhase.end {
            isCapturingScroll = false
            if owner == .move {
                owner = nil
            }
            return .finishStream
        }
        if scrollPhase == ScrollPhase.ended || scrollPhase == ScrollPhase.cancelled {
            if owner == .move {
                owner = nil
            }
            return .liftFingers
        }
        if scrollPhase == ScrollPhase.changed && momentumPhase == MomentumPhase.none && owner == .move {
            return .applyMove
        }
        return .discard
    }

    mutating func handleMagnify(phase: MagnifyPhase, chordMatches: Bool) -> MagnifyAction {
        if phase.contains(.began) {
            isCapturingMagnify = chordMatches
            guard isCapturingMagnify else { return .passThrough }
            guard owner != .move else { return .discard }
            owner = .resize
            return .beginResize
        }

        guard isCapturingMagnify else { return .passThrough }

        if !phase.intersection([.ended, .cancelled]).isEmpty {
            if owner == .resize {
                owner = nil
                isCapturingMagnify = false
                return .liftFingers
            }
            isCapturingMagnify = false
            return .discard
        }
        if owner == .resize {
            return .applyResize
        }
        return .discard
    }
}
