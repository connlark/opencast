import Foundation
import Testing
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

    private var bundleIcons: [String: Any] {
        get throws {
            try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        }
    }
}
