import Foundation
import Testing
@testable import OpenCast

/// The Release diagnostic sink: bounded rotation with one previous
/// generation, appends that are safe from any isolation and lose nothing,
/// and an allow-list check that refuses any key outside the typed schema.
@Suite("Remote job diagnostic log")
struct RemoteJobDiagnosticLogTests {
    @Test("The file rotates at its cap into one previous generation without losing the newest lines")
    func rotatesAtCapIntoOnePreviousGeneration() throws {
        let fileURL = try Self.makeTemporaryDirectory().appending(path: RemoteJobDiagnosticLog.fileName)
        let event = Self.event(kind: .legStarted, leg: .poll)
        let lineSize = try #require(RemoteJobDiagnosticLog.encodedLine(for: event)).count
        let log = RemoteJobDiagnosticLog(fileURL: fileURL, maximumByteCount: lineSize * 3 + 1)

        for _ in 0..<7 {
            log.record(event)
        }
        log.flush()

        let current = try Data(contentsOf: fileURL)
        let previous = try Data(contentsOf: log.previousFileURL)
        #expect(RemoteJobDiagnosticLog.decodeLines(current).count == 1)
        #expect(RemoteJobDiagnosticLog.decodeLines(previous).count == 3)
        #expect(current.count <= lineSize * 3 + 1)
        #expect(previous.count <= lineSize * 3 + 1)
        #expect(RemoteJobDiagnosticLog.decodeLines(current + previous).allSatisfy { $0.kind == .legStarted && $0.leg == .poll })
    }

    @Test("Concurrent appends from many tasks all land as whole lines")
    func concurrentAppendsAllLand() async throws {
        let fileURL = try Self.makeTemporaryDirectory().appending(path: RemoteJobDiagnosticLog.fileName)
        let log = RemoteJobDiagnosticLog(fileURL: fileURL)

        await withTaskGroup(of: Void.self) { group in
            for attempt in 1...64 {
                group.addTask {
                    log.record(Self.event(kind: .legRetried, leg: .poll, attempt: attempt))
                }
            }
        }
        log.flush()

        let events = RemoteJobDiagnosticLog.decodeLines(try Data(contentsOf: fileURL))
        #expect(events.count == 64)
        #expect(Set(events.compactMap(\.attempt)) == Set(1...64))
        #expect(!FileManager.default.fileExists(atPath: log.previousFileURL.path))
    }

    @Test("Only the typed schema's keys pass the allow-list; anything else is refused before it reaches disk")
    func allowListRejectsForeignKeys() throws {
        let event = Self.event(
            kind: .legFailed,
            leg: .create,
            error: RemoteJobDiagnosticError(classifying: URLError(.notConnectedToInternet))
        )
        let line = try #require(RemoteJobDiagnosticLog.encodedLine(for: event))
        #expect(RemoteJobDiagnosticLog.isWithinAllowList(line))
        #expect(RemoteJobDiagnosticLog.decodeLines(line) == [event])
        let text = try #require(String(data: line, encoding: .utf8))
        #expect(!text.contains("notConnectedToInternet"))
        #expect(!text.contains("description"))

        let withTitle = Data(#"{"timestamp":"2026-09-26T00:00:00Z","component":"runner","kind":"runStarted","title":"Private episode"}"#.utf8)
        #expect(!RemoteJobDiagnosticLog.isWithinAllowList(withTitle))
        let withErrorMessage = Data(#"{"timestamp":"2026-09-26T00:00:00Z","component":"runner","kind":"legFailed","error":{"domain":"transport","message":"https://example.com/private.mp3"}}"#.utf8)
        #expect(!RemoteJobDiagnosticLog.isWithinAllowList(withErrorMessage))
        let withStringError = Data(#"{"timestamp":"2026-09-26T00:00:00Z","component":"runner","kind":"legFailed","error":"free text"}"#.utf8)
        #expect(!RemoteJobDiagnosticLog.isWithinAllowList(withStringError))
        #expect(!RemoteJobDiagnosticLog.isWithinAllowList(Data("not json".utf8)))
    }

    private nonisolated static func event(
        kind: RemoteJobDiagnosticEvent.Kind,
        leg: RemoteJobDiagnosticEvent.Leg,
        attempt: Int? = nil,
        error: RemoteJobDiagnosticError? = nil
    ) -> RemoteJobDiagnosticEvent {
        RemoteJobDiagnosticEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 790_000_000),
            component: .runner,
            kind: kind,
            episodeID: "ep-hash",
            jobID: "job-fake-1",
            clientRequestID: "00000000-0000-0000-0000-000000000001",
            purpose: .transcription,
            leg: leg,
            attempt: attempt,
            error: error,
            disposition: .retained
        )
    }

    private nonisolated static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastDiagnosticLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
