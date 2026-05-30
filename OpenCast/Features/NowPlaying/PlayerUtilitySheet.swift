import Foundation

enum PlayerUtilitySheet: String, Identifiable {
    case speed
    case sleep

    var id: String { rawValue }
}
