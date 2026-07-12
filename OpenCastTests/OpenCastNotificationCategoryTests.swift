import Testing
@testable import OpenCast

@MainActor
@Suite("Notification category registration")
struct OpenCastNotificationCategoryTests {
    @Test("Both categories land in the single replacement registration set")
    func registrationSetCarriesBothCategories() {
        let identifiers = OpenCastNotificationCategory.registrationCategories()
            .map(\.identifier)
            .sorted()

        #expect(identifiers == ["OPENCAST_AD_FREE_PASS", "OPENCAST_EPISODE"])
    }

    @Test("Category raw values stay pinned to the wire strings")
    func rawValuesStayPinned() {
        #expect(OpenCastNotificationCategory.episode == "OPENCAST_EPISODE")
        #expect(OpenCastNotificationCategory.adFreePass == "OPENCAST_AD_FREE_PASS")
    }
}
