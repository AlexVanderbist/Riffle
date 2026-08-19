import CoreGraphics

nonisolated struct PendingResize: PendingFrameAdjustment {
    struct Target: PendingFrameTarget {
        let frame: CGRect
        fileprivate let magnification: Double
    }

    private static let magnificationGain = 0.5

    private var baseFrame: CGRect
    private let displayBounds: CGRect
    private let minimumShortEdge: CGFloat
    private let locksGrowth: Bool
    private var pendingMagnification = 0.0
    private var growthCeiling = 1.0

    private var requestedFactor: CGFloat {
        1 + pendingMagnification * Self.magnificationGain
    }

    private var minimumFactor: CGFloat {
        let currentShortEdge = min(baseFrame.width, baseFrame.height)
        return currentShortEdge > minimumShortEdge
            ? minimumShortEdge / currentShortEdge
            : 1
    }

    init(frame: CGRect, displayBounds: CGRect) {
        baseFrame = frame
        self.displayBounds = displayBounds
        minimumShortEdge = min(200, frame.width, frame.height)
        locksGrowth = frame.width > displayBounds.width || frame.height > displayBounds.height
    }

    var target: Target {
        let maximumFactor = min(
            displayBounds.width / baseFrame.width,
            displayBounds.height / baseFrame.height
        )
        let constrainedFactor = requestedFactor > 1
            ? min(requestedFactor, max(1, maximumFactor))
            : max(requestedFactor, minimumFactor)
        let factor = locksGrowth ? min(constrainedFactor, growthCeiling) : constrainedFactor
        let size = CGSize(
            width: baseFrame.width * factor,
            height: baseFrame.height * factor
        )

        let frame = CGRect(
            x: baseFrame.midX - size.width / 2,
            y: baseFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        return Target(frame: frame, magnification: pendingMagnification)
    }

    var targetFrame: CGRect { target.frame }

    mutating func apply(magnification: Double) {
        pendingMagnification += magnification
    }

    mutating func apply(_ magnification: Double) {
        apply(magnification: magnification)
    }

    mutating func accept(to acceptedFrame: CGRect, consuming target: Target) {
        if acceptedFrame == target.frame {
            if locksGrowth {
                let acceptedFactor = min(
                    acceptedFrame.width / baseFrame.width,
                    acceptedFrame.height / baseFrame.height
                )
                growthCeiling = min(growthCeiling, acceptedFactor)
            }
            return
        }

        baseFrame = acceptedFrame
        pendingMagnification -= target.magnification
        if locksGrowth {
            growthCeiling = 1
        }
    }
}
