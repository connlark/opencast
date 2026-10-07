import Foundation
import Testing
@testable import OpenCast

@Suite("About screen resources")
struct SettingsAboutResourceTests {
    @Test("The glass icon model ships at the app bundle root")
    func glassIconModelIsBundled() {
        #expect(Bundle.main.url(forResource: SettingsAboutHeroModel.resourceName, withExtension: "usdz") != nil)
    }
}
