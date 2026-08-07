import Foundation

enum PlayerUtilitySheet: String, Identifiable {
    case speed
    case sleep
    case upNext
    case transcript

    var id: String { rawValue }
}
