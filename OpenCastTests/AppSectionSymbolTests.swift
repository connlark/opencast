import Testing
import UIKit
@testable import OpenCast

@MainActor
@Suite("App section symbols")
struct AppSectionSymbolTests {
    @Test("Every chosen symbol exists", arguments: AppSection.allCases)
    func availability(section: AppSection) {
        #expect(UIImage(systemName: section.systemImage) != nil)
    }
}
