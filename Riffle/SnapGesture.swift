/// The ways a Move Gesture can turn into a snap; each can be switched off in
/// Preferences.
nonisolated enum SnapGesture: String, CaseIterable, Sendable {
    case flick
    case edgePress
    case cornerPress
    case wiggle

    var menuTitle: String {
        switch self {
        case .flick: "Flick: Half or Maximize"
        case .edgePress: "Push to Edge: Half or Maximize"
        case .cornerPress: "Push to Corner: Quarter"
        case .wiggle: "Wiggle: Center at 80%"
        }
    }

    /// SF Symbol shown next to the menu title.
    var menuSymbolName: String {
        switch self {
        case .flick: "hand.draw"
        case .edgePress: "rectangle.lefthalf.filled"
        case .cornerPress: "rectangle.inset.topleft.filled"
        case .wiggle: "rectangle.center.inset.filled"
        }
    }
}
