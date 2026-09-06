import Foundation
import Testing
@testable import OpenCast

struct PlaybackEventLogTests {
    @Test("Playback log appends across writes and reopening without truncating earlier events")
    func appendsAcrossWritesAndReopening() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "events.log")
        let log = PlaybackEventLog(fileURL: fileURL, maximumByteCount: 64)
        await log.record("first")
        await log.record("second")
        let reopened = PlaybackEventLog(fileURL: fileURL, maximumByteCount: 64)
        await reopened.record("third")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "first\nsecond\nthird\n")
    }

    @Test("Playback log survives reopening and retains only one bounded rotation")
    func rotationAndReopening() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "events.log")
        let log = PlaybackEventLog(fileURL: fileURL, maximumByteCount: 12)
        await log.record("first")
        await log.record("second")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "second\n")
        #expect(try String(contentsOf: fileURL.appendingPathExtension("previous"), encoding: .utf8) == "first\n")

        let reopened = PlaybackEventLog(fileURL: fileURL, maximumByteCount: 12)
        await reopened.record("third\nline")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "third line\n")
        #expect(try String(contentsOf: fileURL.appendingPathExtension("previous"), encoding: .utf8) == "second\n")
        await reopened.record(String(repeating: "x", count: 100))
        #expect(try Data(contentsOf: fileURL).count == 12)
        #expect(try Data(contentsOf: fileURL.appendingPathExtension("previous")).count <= 12)
    }
}
