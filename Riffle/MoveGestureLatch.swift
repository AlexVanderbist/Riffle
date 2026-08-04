/// Pure state machine deciding what to do with each event of a scroll stream.
///
/// The Move Gesture latches at scroll phase Began with the chord down and then
/// owns the entire stream through the end of its momentum tail — even if the
/// modifiers are released mid-gesture — so no orphan momentum leaks into the
/// app beneath. A stream that began without the chord is never hijacked.
struct MoveGestureLatch {
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

    enum Action: Equatable {
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

    private(set) var isCapturing = false

    mutating func handle(
        isContinuous: Bool,
        scrollPhase: Int64,
        momentumPhase: Int64,
        chordMatches: Bool
    ) -> Action {
        // Line-based mouse wheels are never ours, even mid-capture.
        guard isContinuous else { return .passThrough }

        // Began is the only place the capture decision is made.
        if scrollPhase == ScrollPhase.began {
            isCapturing = chordMatches
            return isCapturing ? .beginMove : .passThrough
        }

        guard isCapturing else { return .passThrough }

        if momentumPhase == MomentumPhase.end {
            isCapturing = false
            return .finishStream
        }
        if scrollPhase == ScrollPhase.ended || scrollPhase == ScrollPhase.cancelled {
            return .liftFingers
        }
        if scrollPhase == ScrollPhase.changed && momentumPhase == MomentumPhase.none {
            return .applyMove
        }
        return .discard
    }
}
