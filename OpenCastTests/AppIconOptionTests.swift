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

    @Test("Each family lists every colourway once, in the same order")
    func familiesShareColourwayOrder() {
        let classic = AppIconOption.options(in: .classic)
        let glass = AppIconOption.options(in: .glass)

        #expect(classic.map(\.title) == glass.map(\.title))
        #expect(Set(classic.map(\.title)).count == classic.count)
        #expect(classic.count + glass.count == AppIconOption.allCases.count)
        #expect(AppIconOption.allCases.count == 24)
    }

    @Test("Qualified titles are unique and glass ones carry the family prefix")
    func qualifiedTitlesAreUniqueAndPrefixed() {
        let qualifiedTitles = AppIconOption.allCases.map(\.qualifiedTitle)

        #expect(Set(qualifiedTitles).count == qualifiedTitles.count)
        for option in AppIconOption.options(in: .classic) {
            #expect(option.qualifiedTitle == option.title)
        }
        for option in AppIconOption.options(in: .glass) {
            #expect(option.qualifiedTitle == "Glass \(option.title)")
        }
    }

    @Test("Glass bundle names follow AppIconGlass<Title>")
    func glassBundleNamesFollowTitle() {
        for option in AppIconOption.options(in: .glass) {
            #expect(option.rawValue == "AppIconGlass\(option.title)")
            #expect(option.alternateIconName == option.rawValue)
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
