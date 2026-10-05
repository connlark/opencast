import SwiftUI

enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case ember = "AppIcon"
    case ocean = "AppIconOcean"
    case oceanLight = "AppIconOceanLight"
    case sunset = "AppIconSunset"
    case honey = "AppIconHoney"
    case rose = "AppIconRose"
    case violet = "AppIconViolet"
    case lagoon = "AppIconLagoon"
    case fern = "AppIconFern"
    case graphite = "AppIconGraphite"
    case midnight = "AppIconMidnight"
    case abyss = "AppIconAbyss"

    static let primary: AppIconOption = .ember

    /// Maps UIKit's stored alternate icon name back to an option; `nil` and
    /// names from a build that no longer ships them resolve to the primary.
    init(alternateIconName: String?) {
        self = alternateIconName.flatMap(AppIconOption.init(rawValue:)) ?? .primary
    }

    var id: String {
        rawValue
    }

    /// `nil` is how `UIApplication.setAlternateIconName` selects the primary.
    var alternateIconName: String? {
        self == .primary ? nil : rawValue
    }

    var title: String {
        switch self {
        case .ocean:
            "Ocean"
        case .oceanLight:
            "Ocean Light"
        case .ember:
            "Ember"
        case .sunset:
            "Sunset"
        case .honey:
            "Honey"
        case .rose:
            "Rose"
        case .violet:
            "Violet"
        case .lagoon:
            "Lagoon"
        case .fern:
            "Fern"
        case .graphite:
            "Graphite"
        case .midnight:
            "Midnight"
        case .abyss:
            "Abyss"
        }
    }

    var previewImage: ImageResource {
        switch self {
        case .ocean:
            .appIconPreviewOcean
        case .oceanLight:
            .appIconPreviewOceanLight
        case .ember:
            .appIconPreviewEmber
        case .sunset:
            .appIconPreviewSunset
        case .honey:
            .appIconPreviewHoney
        case .rose:
            .appIconPreviewRose
        case .violet:
            .appIconPreviewViolet
        case .lagoon:
            .appIconPreviewLagoon
        case .fern:
            .appIconPreviewFern
        case .graphite:
            .appIconPreviewGraphite
        case .midnight:
            .appIconPreviewMidnight
        case .abyss:
            .appIconPreviewAbyss
        }
    }
}
