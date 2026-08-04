import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass background run log")
struct AdFreePassBackgroundRunLogTests {
    @Test("The DEBUG run log rotates at its cap and stays bounded")
    func runLogRotatesAtCapAndStaysBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AdFreePassRunLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let logURL = directory.appending(path: "session.log")
        let previousURL = logURL.appendingPathExtension("previous")
        let cap = 512

        for index in 0..<200 {
            AdFreePassBackgroundRunLog.record(
                "line \(index) with a reasonably shaped payload",
                logURL: logURL,
                maximumByteCount: cap
            )
        }

        // FileManager attributes, matching the store: URL.resourceValues
        // caches per instance and these URLs are reused across the loop.
        let currentByteCount = try #require(
            (try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue
        )
        let previousByteCount = try #require(
            (try FileManager.default.attributesOfItem(atPath: previousURL.path)[.size] as? NSNumber)?.intValue
        )
        // Current stays under the cap plus one line; one previous generation
        // bounds total use at roughly twice the cap, never unbounded growth.
        #expect(currentByteCount <= cap + 128)
        #expect(previousByteCount <= cap + 128)
        #expect(FileManager.default.fileExists(atPath: previousURL.path))

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents.contains("line 199"))
    }
}
