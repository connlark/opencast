import Foundation

/// The Length chip's choices. A stored rule whose bounds match none of them
/// still evaluates and titles itself through `PlaylistRule.lengthTitle`.
nonisolated enum PlaylistRuleLengthPreset: CaseIterable, Identifiable, Sendable {
    case any
    case under15
    case under30
    case under45
    case under60
    case over30
    case over60
    case over120

    var id: Self {
        self
    }

    var minimumMinutes: Int? {
        switch self {
        case .any, .under15, .under30, .under45, .under60:
            nil
        case .over30:
            30
        case .over60:
            60
        case .over120:
            120
        }
    }

    var maximumMinutes: Int? {
        switch self {
        case .any, .over30, .over60, .over120:
            nil
        case .under15:
            15
        case .under30:
            30
        case .under45:
            45
        case .under60:
            60
        }
    }

    var title: String {
        PlaylistRule.lengthTitle(minimumMinutes: minimumMinutes, maximumMinutes: maximumMinutes)
    }

    static func matching(minimumMinutes: Int?, maximumMinutes: Int?) -> PlaylistRuleLengthPreset? {
        allCases.first { preset in
            preset.minimumMinutes == minimumMinutes && preset.maximumMinutes == maximumMinutes
        }
    }
}
