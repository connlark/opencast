import SwiftUI

enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case ember = "AppIcon"
    case violet = "AppIconViolet"
    case sunset = "AppIconSunset"
    case graphite = "AppIconGraphite"

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
        case .violet:
            "Violet"
        case .sunset:
            "Sunset"
        case .graphite:
            "Graphite"
        }
    }

    var caption: String {
        switch self {
        case .ember:
            "The original navy and orange"
        case .violet:
            "Purple in light, near-black in dark"
        case .sunset:
            "Brand orange, burnt in dark"
        case .graphite:
            "Grey in light, charcoal in dark"
        }
    }

    var previewImage: ImageResource {
        switch self {
        case .ember:
            .appIconPreviewEmber
        case .violet:
            .appIconPreviewViolet
        case .sunset:
            .appIconPreviewSunset
        case .graphite:
            .appIconPreviewGraphite
        }
    }
}
