import SwiftUI

enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case ember = "AppIcon"
    case sunset = "AppIconSunset"
    case honey = "AppIconHoney"
    case rose = "AppIconRose"
    case violet = "AppIconViolet"
    case ocean = "AppIconOcean"
    case lagoon = "AppIconLagoon"
    case fern = "AppIconFern"
    case pearl = "AppIconPearl"
    case graphite = "AppIconGraphite"
    case midnight = "AppIconMidnight"
    case abyss = "AppIconAbyss"

    /// Maps UIKit's stored alternate icon name back to an option; `nil` and
    /// names from a build that no longer ships them resolve to the primary.
    init(alternateIconName: String?) {
        self = alternateIconName.flatMap(AppIconOption.init(rawValue:)) ?? .ember
    }

    var id: String {
        rawValue
    }

    /// `nil` is how `UIApplication.setAlternateIconName` selects the primary.
    var alternateIconName: String? {
        self == .ember ? nil : rawValue
    }

    var title: String {
        switch self {
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
        case .ocean:
            "Ocean"
        case .lagoon:
            "Lagoon"
        case .fern:
            "Fern"
        case .pearl:
            "Pearl"
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
        case .ocean:
            .appIconPreviewOcean
        case .lagoon:
            .appIconPreviewLagoon
        case .fern:
            .appIconPreviewFern
        case .pearl:
            .appIconPreviewPearl
        case .graphite:
            .appIconPreviewGraphite
        case .midnight:
            .appIconPreviewMidnight
        case .abyss:
            .appIconPreviewAbyss
        }
    }
}
