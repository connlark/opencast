/// The two visual treatments every colourway ships in; the picker shows one
/// family at a time.
enum AppIconFamily: String, CaseIterable, Identifiable, Sendable {
    case classic
    case glass

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .classic:
            "Classic"
        case .glass:
            "Glass"
        }
    }
}
