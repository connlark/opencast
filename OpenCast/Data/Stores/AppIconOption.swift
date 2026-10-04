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
    case glassEmber = "AppIconGlassEmber"
    case glassSunset = "AppIconGlassSunset"
    case glassHoney = "AppIconGlassHoney"
    case glassRose = "AppIconGlassRose"
    case glassViolet = "AppIconGlassViolet"
    case glassOcean = "AppIconGlassOcean"
    case glassLagoon = "AppIconGlassLagoon"
    case glassFern = "AppIconGlassFern"
    case glassPearl = "AppIconGlassPearl"
    case glassGraphite = "AppIconGlassGraphite"
    case glassMidnight = "AppIconGlassMidnight"
    case glassAbyss = "AppIconGlassAbyss"

    /// Maps UIKit's stored alternate icon name back to an option; `nil` and
    /// names from a build that no longer ships them resolve to the primary.
    init(alternateIconName: String?) {
        self = alternateIconName.flatMap(AppIconOption.init(rawValue:)) ?? .ember
    }

    /// Every colourway, in picker order, for one family.
    static func options(in family: AppIconFamily) -> [AppIconOption] {
        allCases.filter { $0.family == family }
    }

    var id: String {
        rawValue
    }

    /// `nil` is how `UIApplication.setAlternateIconName` selects the primary.
    var alternateIconName: String? {
        self == .ember ? nil : rawValue
    }

    var family: AppIconFamily {
        switch self {
        case .ember, .sunset, .honey, .rose, .violet, .ocean, .lagoon, .fern, .pearl, .graphite, .midnight, .abyss:
            .classic
        case .glassEmber, .glassSunset, .glassHoney, .glassRose, .glassViolet, .glassOcean, .glassLagoon, .glassFern,
             .glassPearl, .glassGraphite, .glassMidnight, .glassAbyss:
            .glass
        }
    }

    /// The colourway name, shared by both families; the picker shows it under
    /// the family tab.
    var title: String {
        switch self {
        case .ember, .glassEmber:
            "Ember"
        case .sunset, .glassSunset:
            "Sunset"
        case .honey, .glassHoney:
            "Honey"
        case .rose, .glassRose:
            "Rose"
        case .violet, .glassViolet:
            "Violet"
        case .ocean, .glassOcean:
            "Ocean"
        case .lagoon, .glassLagoon:
            "Lagoon"
        case .fern, .glassFern:
            "Fern"
        case .pearl, .glassPearl:
            "Pearl"
        case .graphite, .glassGraphite:
            "Graphite"
        case .midnight, .glassMidnight:
            "Midnight"
        case .abyss, .glassAbyss:
            "Abyss"
        }
    }

    /// Names the option where no family tab gives it context: the Settings
    /// hub value and the picker rows' accessibility identifiers.
    var qualifiedTitle: String {
        switch family {
        case .classic:
            title
        case .glass:
            "Glass \(title)"
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
        case .glassEmber:
            .appIconPreviewGlassEmber
        case .glassSunset:
            .appIconPreviewGlassSunset
        case .glassHoney:
            .appIconPreviewGlassHoney
        case .glassRose:
            .appIconPreviewGlassRose
        case .glassViolet:
            .appIconPreviewGlassViolet
        case .glassOcean:
            .appIconPreviewGlassOcean
        case .glassLagoon:
            .appIconPreviewGlassLagoon
        case .glassFern:
            .appIconPreviewGlassFern
        case .glassPearl:
            .appIconPreviewGlassPearl
        case .glassGraphite:
            .appIconPreviewGlassGraphite
        case .glassMidnight:
            .appIconPreviewGlassMidnight
        case .glassAbyss:
            .appIconPreviewGlassAbyss
        }
    }
}
