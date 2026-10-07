import Foundation

enum SettingsAboutHeroLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
