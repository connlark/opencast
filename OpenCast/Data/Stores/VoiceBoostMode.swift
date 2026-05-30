enum VoiceBoostMode: String, CaseIterable, Identifiable {
    case globalOn
    case perEpisode
    case globalOff

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .globalOn:
            "On"
        case .perEpisode:
            "Episode"
        case .globalOff:
            "Off"
        }
    }

    var fullTitle: String {
        switch self {
        case .globalOn:
            "Global On"
        case .perEpisode:
            "Per Episode"
        case .globalOff:
            "Global Off"
        }
    }
}
