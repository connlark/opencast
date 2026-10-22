import Testing
@testable import OpenCast

@Suite("Network path snapshot")
struct NetworkPathSnapshotTests {
    @Test(
        "Automatic downloads need a satisfied path that is neither metered nor in Low Data Mode",
        arguments: [false, true], [false, true]
    )
    func automaticDownloadsTruthTable(isExpensive: Bool, isConstrained: Bool) {
        let satisfied = NetworkPathSnapshot(isSatisfied: true, isExpensive: isExpensive, isConstrained: isConstrained)
        let unsatisfied = NetworkPathSnapshot(isSatisfied: false, isExpensive: isExpensive, isConstrained: isConstrained)

        #expect(satisfied.allowsAutomaticDownloads == (!isExpensive && !isConstrained))
        #expect(!unsatisfied.allowsAutomaticDownloads)
    }

    @Test("An unreadable path never allows automatic downloads")
    func unavailableBlocksAutomaticDownloads() {
        #expect(!NetworkPathSnapshot.unavailable.allowsAutomaticDownloads)
    }
}
