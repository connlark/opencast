import Foundation
import Testing
import UIKit
@testable import OpenCast

@MainActor
@Suite("App icon options")
struct AppIconOptionTests {
    @Test("Alternate options and the bundle's alternate icons agree")
    func alternateOptionsMatchBundleAlternateIcons() throws {
        let alternateIcons = try #require(bundleIcons["CFBundleAlternateIcons"] as? [String: Any])
        let optionNames = Set(AppIconOption.allCases.compactMap(\.alternateIconName))

        #expect(optionNames == Set(alternateIcons.keys))
        for (name, entry) in alternateIcons {
            let iconName = (entry as? [String: Any])?["CFBundleIconName"] as? String
            #expect(iconName == name)
        }
    }

    @Test("Primary option is the bundle's primary icon")
    func primaryOptionIsBundlePrimaryIcon() throws {
        let primaryIcon = try #require(bundleIcons["CFBundlePrimaryIcon"] as? [String: Any])

        #expect(primaryIcon["CFBundleIconName"] as? String == AppIconOption.ember.rawValue)
        #expect(AppIconOption.ember.alternateIconName == nil)
    }

    @Test("Stored names map back to options, unknown names to the primary")
    func storedNamesMapToOptions() {
        #expect(AppIconOption(alternateIconName: nil) == .ember)
        #expect(AppIconOption(alternateIconName: "AppIconRetired") == .ember)
        for option in AppIconOption.allCases {
            #expect(AppIconOption(alternateIconName: option.alternateIconName) == option)
        }
    }

    @Test("Every option's preview image loads")
    func previewImagesLoad() {
        for option in AppIconOption.allCases {
            let image = UIImage(resource: option.previewImage)
            #expect(image.size.width > 0, "\(option.title) preview should load")
        }
    }

    private var bundleIcons: [String: Any] {
        get throws {
            try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        }
    }
}
