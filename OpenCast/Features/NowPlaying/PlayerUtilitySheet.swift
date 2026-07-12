import Foundation

enum PlayerUtilitySheet: String, Identifiable {
    case speed
    case sleep
    case transcript

    var id: String { rawValue }
}
