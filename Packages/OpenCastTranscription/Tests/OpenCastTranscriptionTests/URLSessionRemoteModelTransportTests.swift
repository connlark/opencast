import Foundation
@testable import OpenCastTranscription
import Testing

@Suite("URLSession remote model transport", .serialized)
struct URLSessionRemoteModelTransportTests {
    private let sourceURL = URL(string: "https://models.example.test/v1/models/assets/model/v1/weight.bin")!

    @Test("Chunked delivery writes a byte-exact file")
    func chunkedDeliveryWritesByteExactFile() async throws {
        let body = patternedBody(byteCount: 300_000)
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 200, headers: [:], body: body)],
            deliveryChunkByteCount: 64 * 1_024
        )
        let destination = try temporaryDestination()
        defer {
            try? FileManager.default.removeItem(at: destination)
        }

        let response = try await makeTransport().download(
            from: sourceURL,
            to: destination,
            expectedByteCount: Int64(body.count),
            maximumByteCount: 1_024 * 1_024,
            progress: nil
        )

        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test("Mid-stream over-cap fails and deletes the destination")
    func midStreamOverCapFailsAndDeletesDestination() async throws {
        let body = patternedBody(byteCount: 200_000)
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 200, headers: [:], body: body)],
            deliveryChunkByteCount: 64 * 1_024
        )
        let destination = try temporaryDestination()

        await expectInvalidManifest {
            _ = try await makeTransport().download(
                from: sourceURL,
                to: destination,
                expectedByteCount: 100_000,
                maximumByteCount: 1_024 * 1_024,
                progress: nil
            )
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("Cancellation mid-download deletes the destination")
    func cancellationMidDownloadDeletesDestination() async throws {
        let body = patternedBody(byteCount: 200_000)
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 200, headers: [:], body: body)],
            finishesResponses: false,
            deliveryChunkByteCount: 64 * 1_024
        )
        let destination = try temporaryDestination()
        let transport = makeTransport()

        let (firstChunk, firstChunkContinuation) = AsyncStream<Int64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let download = Task {
            _ = try await transport.download(
                from: sourceURL,
                to: destination,
                expectedByteCount: Int64(body.count),
                maximumByteCount: 1_024 * 1_024,
                progress: { bytesReceived in
                    firstChunkContinuation.yield(bytesReceived)
                }
            )
        }
        var chunkIterator = firstChunk.makeAsyncIterator()
        _ = await chunkIterator.next()
        download.cancel()

        await #expect(throws: CancellationError.self) {
            try await download.value
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("Short body fails byte-exact validation and deletes the destination")
    func shortBodyFailsByteExactValidation() async throws {
        let body = patternedBody(byteCount: 500)
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 200, headers: [:], body: body)]
        )
        let destination = try temporaryDestination()

        await expectInvalidManifest {
            _ = try await makeTransport().download(
                from: sourceURL,
                to: destination,
                expectedByteCount: 1_000,
                maximumByteCount: 1_024 * 1_024,
                progress: nil
            )
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("Declared over-limit content length fails before writing")
    func declaredOverLimitContentLengthFails() async throws {
        let body = patternedBody(byteCount: 100)
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 200, headers: ["Content-Length": "2000000"], body: body)]
        )
        let destination = try temporaryDestination()

        await expectInvalidManifest {
            _ = try await makeTransport().download(
                from: sourceURL,
                to: destination,
                expectedByteCount: 100,
                maximumByteCount: 1_000_000,
                progress: nil
            )
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("Non-2xx response fails without writing")
    func non2xxResponseFails() async throws {
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 404, headers: [:], body: Data())]
        )
        let destination = try temporaryDestination()

        do {
            _ = try await makeTransport().download(
                from: sourceURL,
                to: destination,
                expectedByteCount: 100,
                maximumByteCount: 1_000_000,
                progress: nil
            )
            Issue.record("Expected remoteModelDownloadFailed")
        } catch let error as OpenCastTranscriptionError {
            guard case .remoteModelDownloadFailed = error else {
                Issue.record("Expected remoteModelDownloadFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected remoteModelDownloadFailed, got \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("Progress lands on the full byte count")
    func progressLandsOnFullByteCount() async throws {
        let body = patternedBody(byteCount: 300_000)
        RemoteModelTestURLProtocol.configure(
            stubs: [(statusCode: 200, headers: [:], body: body)],
            deliveryChunkByteCount: 64 * 1_024
        )
        let destination = try temporaryDestination()
        defer {
            try? FileManager.default.removeItem(at: destination)
        }

        let recorded = RecordedProgress()
        _ = try await makeTransport().download(
            from: sourceURL,
            to: destination,
            expectedByteCount: Int64(body.count),
            maximumByteCount: 1_024 * 1_024,
            progress: { bytesReceived in
                recorded.append(bytesReceived)
            }
        )

        let values = recorded.values
        #expect(values.isEmpty == false)
        #expect(values.last == Int64(body.count))
        #expect(values == values.sorted())
    }

    @Test("Delegate publishes mid-file progress per chunk")
    func delegatePublishesMidFileProgressPerChunk() throws {
        let destination = try temporaryDestination()
        defer {
            try? FileManager.default.removeItem(at: destination)
        }
        let recorded = RecordedProgress()
        let delegate = URLSessionRemoteModelDownloadDelegate(
            url: sourceURL,
            destinationURL: destination,
            expectedByteCount: 200_000,
            maximumByteCount: 1_000_000,
            progressInterval: .zero,
            progress: { bytesReceived in
                recorded.append(bytesReceived)
            }
        )
        let session = URLSession.shared
        let task = session.dataTask(with: sourceURL)
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        var disposition: URLSession.ResponseDisposition?
        delegate.urlSession(session, dataTask: task, didReceive: response) { resolved in
            disposition = resolved
        }
        #expect(disposition == .allow)

        delegate.urlSession(session, dataTask: task, didReceive: patternedBody(byteCount: 100_000))
        delegate.urlSession(session, dataTask: task, didReceive: patternedBody(byteCount: 100_000))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)

        #expect(recorded.values == [100_000, 200_000])
        #expect(try Data(contentsOf: destination).count == 200_000)
    }

    private func makeTransport() -> URLSessionRemoteModelTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteModelTestURLProtocol.self]
        return URLSessionRemoteModelTransport(session: URLSession(configuration: configuration))
    }

    private func temporaryDestination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "download.bin")
    }

    private func patternedBody(byteCount: Int) -> Data {
        Data((0..<byteCount).lazy.map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private func expectInvalidManifest(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected invalid manifest")
        } catch let error as OpenCastTranscriptionError {
            guard case .invalidRemoteManifest = error else {
                Issue.record("Expected invalidRemoteManifest, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected invalidRemoteManifest, got \(error)")
        }
    }
}

nonisolated private final class RecordedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    var values: [Int64] {
        lock.withLock { storage }
    }

    func append(_ value: Int64) {
        lock.withLock {
            storage.append(value)
        }
    }
}
