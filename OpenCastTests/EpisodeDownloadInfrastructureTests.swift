import Foundation
import OpenCastCore
import OpenCastTranscription
import os
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode download infrastructure", .serialized)
struct EpisodeDownloadInfrastructureTests {
    @Test("URLSession downloader appends ranges and restarts safely")
    func urlSessionDownloaderRangeBehavior() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let configuration = OpenCastURLSessionFactory.downloadConfiguration()
        configuration.protocolClasses = [EpisodeDownloadTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let downloader = URLSessionEpisodeAudioDownloader(session: session)
        let sourceURL = try #require(URL(string: "https://example.com/episode.mp3"))

        let appendURL = baseDirectory.appending(path: "append.partial")
        try Data("abc".utf8).write(to: appendURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 3-5/6",
                    "ETag": "\"version-1\"",
                ],
                body: Data("def".utf8)
            ),
        ])
        var appendMetadata: EpisodeDownloadResponseMetadata?
        var appendProgress: (Int64, Int64?)?

        try await downloader.download(
            from: sourceURL,
            to: appendURL,
            resume: EpisodeDownloadResumeContext(
                offset: 3,
                entityTag: "\"version-1\"",
                lastModified: nil
            ),
            onResponseMetadata: { appendMetadata = $0 },
            progress: { appendProgress = ($0, $1) }
        )

        let appendRequest = try #require(EpisodeDownloadTestURLProtocol.requests.first)
        #expect(appendRequest.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        // The media profile overrides the session's general identity per request.
        #expect(appendRequest.value(forHTTPHeaderField: "User-Agent") == OpenCastMediaRequestProfile.userAgent)
        #expect(OpenCastMediaRequestProfile.userAgent != OpenCastURLSessionFactory.userAgent)
        #expect(OpenCastMediaRequestProfile.userAgent.hasSuffix("/\(OpenCastMediaRequestProfile.version)"))
        #expect(!OpenCastMediaRequestProfile.userAgent.contains("://"))
        #expect(appendRequest.value(forHTTPHeaderField: "Range") == "bytes=3-")
        #expect(appendRequest.value(forHTTPHeaderField: "If-Range") == "\"version-1\"")
        #expect(appendMetadata?.entityTag == "\"version-1\"")
        #expect(appendProgress?.0 == 6)
        #expect(appendProgress?.1 == 6)
        #expect(try Data(contentsOf: appendURL) == Data("abcdef".utf8))

        let encodedURL = baseDirectory.appending(path: "encoded.partial")
        let encodedPartial = Data("abc".utf8)
        try encodedPartial.write(to: encodedURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 206,
                headers: [
                    "Content-Encoding": "gzip",
                    "Content-Range": "bytes 3-5/6",
                ],
                body: Data("def".utf8)
            ),
        ])

        do {
            try await downloader.download(
                from: sourceURL,
                to: encodedURL,
                resume: EpisodeDownloadResumeContext(
                    offset: 3,
                    entityTag: "\"version-1\"",
                    lastModified: nil
                ),
                onResponseMetadata: { _ in },
                progress: { _, _ in }
            )
            Issue.record("Expected a content-coded range response to fail.")
        } catch EpisodeDownloadError.unsupportedContentEncoding {
        } catch {
            Issue.record("Expected unsupported content encoding, got \(error).")
        }

        let encodedRequest = try #require(EpisodeDownloadTestURLProtocol.requests.first)
        #expect(encodedRequest.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(try Data(contentsOf: encodedURL) == encodedPartial)

        let restartURL = baseDirectory.appending(path: "restart.partial")
        try Data("stale".utf8).write(to: restartURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 200,
                headers: ["Content-Length": "5"],
                body: Data("fresh".utf8)
            ),
        ])

        try await downloader.download(
            from: sourceURL,
            to: restartURL,
            resume: EpisodeDownloadResumeContext(
                offset: 5,
                entityTag: nil,
                lastModified: "Wed, 01 Jul 2026 12:00:00 GMT"
            ),
            onResponseMetadata: { _ in },
            progress: { _, _ in }
        )

        let restartRequest = try #require(EpisodeDownloadTestURLProtocol.requests.first)
        #expect(restartRequest.value(forHTTPHeaderField: "Range") == "bytes=5-")
        #expect(
            restartRequest.value(forHTTPHeaderField: "If-Range")
                == "Wed, 01 Jul 2026 12:00:00 GMT"
        )
        #expect(try Data(contentsOf: restartURL) == Data("fresh".utf8))

        let unvalidatedURL = baseDirectory.appending(path: "unvalidated.partial")
        try Data("stale".utf8).write(to: unvalidatedURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 200,
                headers: ["Content-Length": "5"],
                body: Data("fresh".utf8)
            ),
        ])

        try await downloader.download(
            from: sourceURL,
            to: unvalidatedURL,
            resume: EpisodeDownloadResumeContext(
                offset: 5,
                entityTag: nil,
                lastModified: nil
            ),
            onResponseMetadata: { _ in },
            progress: { _, _ in }
        )

        let unvalidatedRequest = try #require(EpisodeDownloadTestURLProtocol.requests.first)
        #expect(unvalidatedRequest.value(forHTTPHeaderField: "Range") == nil)
        #expect(unvalidatedRequest.value(forHTTPHeaderField: "If-Range") == nil)
        #expect(try Data(contentsOf: unvalidatedURL) == Data("fresh".utf8))

        let weakValidatorURL = baseDirectory.appending(path: "weak-validator.partial")
        try Data("stale".utf8).write(to: weakValidatorURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 200,
                headers: ["Content-Length": "5"],
                body: Data("fresh".utf8)
            ),
        ])

        try await downloader.download(
            from: sourceURL,
            to: weakValidatorURL,
            resume: EpisodeDownloadResumeContext(
                offset: 5,
                entityTag: "W/\"weak-version\"",
                lastModified: "Wed, 01 Jul 2026 12:00:00 GMT"
            ),
            onResponseMetadata: { _ in },
            progress: { _, _ in }
        )

        let weakValidatorRequest = try #require(EpisodeDownloadTestURLProtocol.requests.first)
        #expect(weakValidatorRequest.value(forHTTPHeaderField: "Range") == "bytes=5-")
        #expect(
            weakValidatorRequest.value(forHTTPHeaderField: "If-Range")
                == "Wed, 01 Jul 2026 12:00:00 GMT"
        )

        let shortRangeURL = baseDirectory.appending(path: "short-range.partial")
        try Data("abc".utf8).write(to: shortRangeURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 206,
                headers: ["Content-Range": "bytes 3-5/6"],
                body: Data("de".utf8)
            ),
        ])

        do {
            try await downloader.download(
                from: sourceURL,
                to: shortRangeURL,
                resume: EpisodeDownloadResumeContext(
                    offset: 3,
                    entityTag: "\"version-1\"",
                    lastModified: nil
                ),
                onResponseMetadata: { _ in },
                progress: { _, _ in }
            )
            Issue.record("Expected a short range response to fail.")
        } catch EpisodeDownloadError.interrupted {
        } catch {
            Issue.record("Expected interrupted download, got \(error).")
        }

        let retryURL = baseDirectory.appending(path: "retry.partial")
        try Data("abc".utf8).write(to: retryURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 416,
                headers: ["Content-Range": "bytes */6"],
                body: Data()
            ),
            (
                statusCode: 200,
                headers: ["Content-Length": "6"],
                body: Data("abcdef".utf8)
            ),
        ])

        try await downloader.download(
            from: sourceURL,
            to: retryURL,
            resume: EpisodeDownloadResumeContext(
                offset: 3,
                entityTag: "\"version-1\"",
                lastModified: nil
            ),
            onResponseMetadata: { _ in },
            progress: { _, _ in }
        )

        let retryRequests = EpisodeDownloadTestURLProtocol.requests
        try #require(retryRequests.count == 2)
        #expect(
            retryRequests[0].value(forHTTPHeaderField: "Range") == "bytes=3-"
        )
        #expect(retryRequests[1].value(forHTTPHeaderField: "Range") == nil)
        #expect(try Data(contentsOf: retryURL) == Data("abcdef".utf8))

        let cancellationURL = baseDirectory.appending(path: "cancellation.partial")
        let cancellationBody = Data(repeating: 0x61, count: 64 * 1_024)
        EpisodeDownloadTestURLProtocol.configure(
            stubs: [
                (
                    statusCode: 200,
                    headers: ["Content-Length": "\(cancellationBody.count * 2)"],
                    body: cancellationBody
                ),
            ],
            finishesResponses: false
        )
        var cancellationProgress: Int64 = 0
        let cancellationTask = Task {
            try await downloader.download(
                from: sourceURL,
                to: cancellationURL,
                resume: nil,
                onResponseMetadata: { _ in },
                progress: { bytesReceived, _ in
                    cancellationProgress = bytesReceived
                }
            )
        }
        defer { cancellationTask.cancel() }

        let progressDeadline = ContinuousClock.now + .seconds(60)
        while cancellationProgress < Int64(cancellationBody.count), ContinuousClock.now < progressDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(cancellationProgress == Int64(cancellationBody.count))
        cancellationTask.cancel()
        do {
            try await cancellationTask.value
            Issue.record("Expected the suspended URLSession download to be cancelled.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        #expect(try Data(contentsOf: cancellationURL) == cancellationBody)

        let metadataRaceURL = baseDirectory.appending(path: "metadata-race.partial")
        try Data("old-version-prefix".utf8).write(to: metadataRaceURL)
        EpisodeDownloadTestURLProtocol.configure(stubs: [
            (
                statusCode: 200,
                headers: [
                    "Content-Length": "8",
                    "ETag": "\"version-2\"",
                ],
                body: Data("new-body".utf8)
            ),
        ])
        let metadataRaceTask = Task {
            try await downloader.download(
                from: sourceURL,
                to: metadataRaceURL,
                resume: EpisodeDownloadResumeContext(
                    offset: Int64(Data("old-version-prefix".utf8).count),
                    entityTag: "\"version-1\"",
                    lastModified: nil
                ),
                onResponseMetadata: { _ in
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                },
                progress: { _, _ in }
            )
        }

        do {
            try await metadataRaceTask.value
            Issue.record("Expected cancellation during restart metadata publication.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        #expect(try Data(contentsOf: metadataRaceURL).isEmpty)
    }

    @Test("URLSession downloader coalesces rapid network progress")
    func urlSessionDownloaderCoalescesRapidProgress() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EpisodeDownloadTestURLProtocol.self]
        let downloader = URLSessionEpisodeAudioDownloader(configuration: configuration)
        let sourceURL = try #require(URL(string: "https://example.com/large-episode.mp3"))
        let destinationURL = baseDirectory.appending(path: "large-episode.partial")
        let body = Data(repeating: 0x5A, count: 4 * 1_024 * 1_024)
        EpisodeDownloadTestURLProtocol.configure(
            stubs: [(
                statusCode: 200,
                headers: ["Content-Length": body.count.description],
                body: body
            )],
            deliveryChunkByteCount: 1_024
        )
        var progressEvents: [(Int64, Int64?)] = []

        try await downloader.download(
            from: sourceURL,
            to: destinationURL,
            resume: nil,
            onResponseMetadata: { _ in },
            progress: { progressEvents.append(($0, $1)) }
        )

        #expect(progressEvents.count < 16)
        #expect(progressEvents.last?.0 == Int64(body.count))
        #expect(progressEvents.last?.1 == Int64(body.count))
        #expect(try Data(contentsOf: destinationURL) == body)
    }

    @Test("Response disposition resolves .allow only after metadata delivery")
    func delegateResolvesAllowAfterMetadataDelivery() async throws {
        let directory = try makeTemporaryDirectory()
        let temporaryURL = directory.appending(path: "delegate-disposition.partial")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let (_, progressContinuation) = AsyncStream<URLSessionEpisodeAudioDownloadDelegate.ProgressUpdate>.makeStream()
        let metadataDelivered = OSAllocatedUnfairLock(initialState: false)
        let delegate = URLSessionEpisodeAudioDownloadDelegate(
            temporaryURL: temporaryURL,
            resumeOffset: 0,
            resume: nil,
            progressInterval: .milliseconds(250),
            progressContinuation: progressContinuation,
            onResponseMetadata: { _ in
                metadataDelivered.withLock { $0 = true }
            }
        )
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "https://example.com/audio.mp3")!
        let dataTask = session.dataTask(with: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "6"]
        )!

        let disposition = await withCheckedContinuation { continuation in
            delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
                continuation.resume(returning: disposition)
            }
        }

        // Metadata lands strictly before the disposition resolves, and an
        // uncancelled delivery resolves .allow. (The cancel-during-delivery
        // side is pinned by the metadata-race leg of the append/restart
        // downloader test — the callback CAN cancel the disposition task.)
        #expect(disposition == .allow)
        #expect(metadataDelivered.withLock { $0 })
    }

    @Test("Response metadata carries the Content-Disposition filename only when the header is sent")
    func delegateCapturesFormatHints() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://example.com/get/abc"))

        let named = try await deliveredMetadata(
            for: try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "6",
                    "Content-Disposition": "attachment; filename=\"a.m4a\"",
                    "Content-Type": "application/json",
                ]
            )),
            in: directory
        )
        #expect(named?.suggestedFilename == "a.m4a")
        #expect(named?.mimeType == "application/json")

        let unnamed = try await deliveredMetadata(
            for: try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "6", "Content-Type": "audio/mpeg"]
            )),
            in: directory
        )
        #expect(unnamed?.suggestedFilename == nil)
        #expect(unnamed?.mimeType == "audio/mpeg")

        let resumed = try await deliveredMetadata(
            for: try #require(HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Range": "bytes 3-5/6",
                    "Content-Disposition": "attachment; filename=\"b.mp3\"",
                ]
            )),
            resumeOffset: 3,
            in: directory
        )
        #expect(resumed?.suggestedFilename == "b.mp3")
        #expect(resumed?.entityTag == "\"version-1\"")
    }

    @Test("Settled path names an extension-less download after its bytes, then its response")
    func settledPathNamesExtensionlessDownloads() throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)
        try fileStore.prepareDownloadsDirectory()
        let fileURL = fileStore.temporaryFileURL(episodeID: "settle", token: "token")
        let extensionlessURL = try #require(URL(string: "https://example.com/get/abc?file=track.mp3"))
        let phpURL = try #require(URL(string: "https://example.com/feed/episode.php"))
        let mp3URL = try #require(URL(string: "https://example.com/episode.mp3"))
        func settledExtension(
            _ header: Data,
            sourceURL: URL? = nil,
            suggestedFilename: String? = nil,
            mimeType: String? = nil
        ) throws -> String {
            try (header + Data(repeating: 0x00, count: 16)).write(to: fileURL)
            let relativePath = fileStore.settledRelativePath(
                episodeID: "settle",
                sourceAudioURL: sourceURL ?? extensionlessURL,
                responseMetadata: EpisodeDownloadResponseMetadata(
                    entityTag: nil,
                    lastModified: nil,
                    suggestedFilename: suggestedFilename,
                    mimeType: mimeType
                ),
                fileURL: fileURL
            )
            #expect(relativePath.hasPrefix("\(EpisodeDownloadFileStore.directoryName)/settle."))
            return URL(filePath: relativePath).pathExtension
        }
        let fixtures = EpisodeDownloadAudioFixtures.self
        let taggedMP3 = fixtures.taggedMP3
        let taggedADTS = fixtures.id3Tagged(fixtures.adtsFrameHeader)
        let mpeg4 = Data([0x00, 0x00, 0x00, 0x20] + Array("ftypM4A ".utf8))
        let unrecognized = Data([0x12, 0x34, 0x56, 0x78])
        // "ID3" with an invalid version byte: not a tag, so it proves nothing.
        let malformedTag = Data("ID3".utf8) + Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        #expect(try settledExtension(Data(fixtures.mpegFrameHeader)) == "mp3")
        #expect(try settledExtension(Data(fixtures.adtsFrameHeader)) == "aac")
        #expect(try settledExtension(taggedMP3) == "mp3")
        #expect(try settledExtension(taggedADTS) == "aac")
        #expect(try settledExtension(fixtures.id3Tagged(fixtures.mpegFrameHeader, bodyByteCount: 20_000)) == "mp3")
        #expect(try settledExtension(fixtures.id3Tagged(fixtures.adtsFrameHeader, trailingPadding: 300)) == "aac")
        #expect(try settledExtension(mpeg4) == "m4a")
        #expect(try settledExtension(Data("OggS".utf8)) == "ogg")
        #expect(try settledExtension(Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVE".utf8)) == "wav")
        #expect(try settledExtension(Data("fLaC".utf8)) == "flac")
        #expect(try settledExtension(Data("FORM".utf8) + Data([0, 0, 0, 0]) + Data("AIFF".utf8)) == "aiff")
        #expect(try settledExtension(Data("caff".utf8)) == "caf")
        #expect(try settledExtension(unrecognized) == EpisodeDownloadFileStore.fallbackExtension)
        #expect(try settledExtension(unrecognized, suggestedFilename: "x.m4a", mimeType: "application/json") == "m4a")
        #expect(try settledExtension(unrecognized, mimeType: "audio/mpeg") == "mp3")
        #expect(try settledExtension(unrecognized, mimeType: "audio/x-m4a") == "m4a")
        #expect(try settledExtension(unrecognized, mimeType: "audio/mp4; codecs=mp4a.40.2") == "m4a")
        #expect(try settledExtension(unrecognized, suggestedFilename: "x.json", mimeType: "application/json")
            == EpisodeDownloadFileStore.fallbackExtension)
        #expect(try settledExtension(malformedTag) == EpisodeDownloadFileStore.fallbackExtension)
        #expect(try settledExtension(malformedTag, mimeType: "audio/aac") == "aac")
        #expect(try settledExtension(taggedMP3, sourceURL: phpURL) == "mp3")
        #expect(try settledExtension(mpeg4, sourceURL: mp3URL) == "mp3")
        #expect(try settledExtension(taggedMP3, suggestedFilename: "x.m4a") == "mp3")
        #expect(try settledExtension(taggedADTS, suggestedFilename: "x.mp3", mimeType: "audio/mpeg") == "aac")
    }

    @Test("Completed sibling probe matches only an unclaimed audio file of the recorded size and hash")
    func completedSiblingProbe() throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)
        try fileStore.prepareDownloadsDirectory()
        let episodeID = "sibling"
        let audio = Data("ID3 sibling audio".utf8)
        let size = Int64(audio.count)
        let hash = OpenCastSHA256.hash(audio)
        func probe(sha256: String = "", excluding: Set<String> = []) -> String? {
            fileStore.completedSiblingRelativePath(
                episodeID: episodeID,
                expectedSize: size,
                expectedSHA256: sha256,
                excluding: excluding
            )
        }
        try audio.write(to: fileStore.temporaryFileURL(episodeID: episodeID, token: "token"))
        try audio.write(to: fileStore.pausedPartialFileURL(episodeID: episodeID))
        #expect(probe() == nil)

        let wrongSizePath = fileStore.relativePath(episodeID: episodeID, extension: "m4a")
        try Data("ID3 a longer sibling".utf8).write(to: fileStore.fileURL(relativePath: wrongSizePath))
        #expect(probe() == nil)

        // Same size, other bytes: only a record without a hash may adopt it.
        let staleSiblingPath = fileStore.relativePath(episodeID: episodeID, extension: "aac")
        try Data("ID3 stale sibling".utf8).write(to: fileStore.fileURL(relativePath: staleSiblingPath))
        #expect(probe() == staleSiblingPath)
        #expect(probe(sha256: hash) == nil)

        let siblingPath = fileStore.relativePath(episodeID: episodeID, extension: "mp3")
        try audio.write(to: fileStore.fileURL(relativePath: siblingPath))
        #expect(probe(sha256: hash) == siblingPath)
        #expect(probe(sha256: hash, excluding: [siblingPath]) == nil)
    }

    @Test("Resume response policy handles partial, full, and unsatisfiable responses")
    func resumeResponsePolicyHandlesExpectedResponses() {
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 128,
                headers: ["content-range": "bytes 128-511/1024"]
            ) == .append(bytesExpected: 1024)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 200,
                resumeOffset: 128,
                headers: ["Content-Length": "1024"]
            ) == .restart(bytesExpected: 1024, requiresNewRequest: false)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 416,
                resumeOffset: 128,
                headers: [:]
            ) == .restart(bytesExpected: nil, requiresNewRequest: true)
        )
    }

    @Test("Resume response policy rejects unsafe append responses")
    func resumeResponsePolicyRejectsUnsafeAppendResponses() {
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 128,
                headers: ["Content-Range": "bytes 64-511/1024"]
            ) == .restart(bytesExpected: nil, requiresNewRequest: true)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 128,
                headers: [:]
            ) == .restart(bytesExpected: nil, requiresNewRequest: true)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 128,
                headers: ["Content-Range": "bytes 128-511/not-a-number"]
            ) == .restart(bytesExpected: nil, requiresNewRequest: true)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 206,
                resumeOffset: 128,
                headers: ["Content-Range": "bytes 128-511/*"]
            ) == .restart(bytesExpected: nil, requiresNewRequest: true)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 416,
                resumeOffset: 0,
                headers: [:]
            ) == .fail(statusCode: 416)
        )
        #expect(
            EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: 503,
                resumeOffset: 128,
                headers: [:]
            ) == .fail(statusCode: 503)
        )
    }

    @Test("Paused partial has stable name and moves back to a token temporary file")
    func pausedPartialRoundTrip() throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)
        let episodeID = "episode with spaces"
        let temporaryURL = fileStore.temporaryFileURL(episodeID: episodeID, token: "first")
        let partialData = Data("partial audio".utf8)
        try fileStore.prepareDownloadsDirectory()
        try partialData.write(to: temporaryURL)

        let size = try fileStore.promoteTemporaryFileToPausedPartial(
            temporaryURL,
            episodeID: episodeID
        )
        let pausedURL = fileStore.pausedPartialFileURL(episodeID: episodeID)
        let sourceURL = try #require(URL(string: "https://example.com/audio.partial"))
        let finalRelativePath = fileStore.relativePath(
            episodeID: episodeID,
            sourceAudioURL: sourceURL
        )

        #expect(pausedURL.lastPathComponent == "episode-with-spaces.partial")
        #expect(fileStore.fileURL(relativePath: finalRelativePath) != pausedURL)
        #expect(size == Int64(partialData.count))
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path) == false)
        #expect(try Data(contentsOf: pausedURL) == partialData)

        let resumedURL = try fileStore.movePausedPartialToTemporaryFile(
            episodeID: episodeID,
            token: "second"
        )
        #expect(resumedURL == fileStore.temporaryFileURL(episodeID: episodeID, token: "second"))
        #expect(FileManager.default.fileExists(atPath: pausedURL.path) == false)
        #expect(try Data(contentsOf: resumedURL) == partialData)
    }

    @Test("Adopting a temporary partial keeps the newest file and removes older tokens")
    func adoptingNewestTemporaryPartial() throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)
        let episodeID = "adopt-partial"
        let olderURL = fileStore.temporaryFileURL(episodeID: episodeID, token: "older")
        let newerURL = fileStore.temporaryFileURL(episodeID: episodeID, token: "newer")
        let olderData = Data("old".utf8)
        let newerData = Data("newer partial".utf8)
        try fileStore.prepareDownloadsDirectory()
        try olderData.write(to: olderURL)
        try newerData.write(to: newerURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: olderURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: newerURL.path
        )

        let adoptedSize = try fileStore.adoptNewestTemporaryPartial(episodeID: episodeID)
        let pausedURL = fileStore.pausedPartialFileURL(episodeID: episodeID)

        #expect(adoptedSize == Int64(newerData.count))
        #expect(try Data(contentsOf: pausedURL) == newerData)
        #expect(FileManager.default.fileExists(atPath: olderURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: newerURL.path) == false)
    }

    @Test("Removing a paused partial leaves token temporary files untouched")
    func removingPausedPartialLeavesTemporaryFiles() throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)
        let episodeID = "remove-paused"
        let temporaryURL = fileStore.temporaryFileURL(episodeID: episodeID, token: "active")
        let pausedURL = fileStore.pausedPartialFileURL(episodeID: episodeID)
        try fileStore.prepareDownloadsDirectory()
        try Data("temporary".utf8).write(to: temporaryURL)
        try Data("paused".utf8).write(to: pausedURL)

        try fileStore.removePausedPartial(episodeID: episodeID)

        #expect(FileManager.default.fileExists(atPath: pausedURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test("Adopting from a missing downloads directory returns nil")
    func adoptingFromMissingDirectoryReturnsNil() throws {
        let baseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)

        #expect(try fileStore.adoptNewestTemporaryPartial(episodeID: "missing") == nil)
    }

    private func deliveredMetadata(
        for response: HTTPURLResponse,
        resumeOffset: Int64 = 0,
        in directory: URL
    ) async throws -> EpisodeDownloadResponseMetadata? {
        let temporaryURL = directory.appending(path: "\(UUID().uuidString).partial")
        try Data(repeating: 0x61, count: Int(resumeOffset)).write(to: temporaryURL)
        let (_, progressContinuation) = AsyncStream<URLSessionEpisodeAudioDownloadDelegate.ProgressUpdate>.makeStream()
        let delivered = OSAllocatedUnfairLock<EpisodeDownloadResponseMetadata?>(initialState: nil)
        let delegate = URLSessionEpisodeAudioDownloadDelegate(
            temporaryURL: temporaryURL,
            resumeOffset: resumeOffset,
            resume: resumeOffset > 0
                ? EpisodeDownloadResumeContext(offset: resumeOffset, entityTag: "\"version-1\"", lastModified: nil)
                : nil,
            progressInterval: .milliseconds(250),
            progressContinuation: progressContinuation,
            onResponseMetadata: { metadata in
                delivered.withLock { $0 = metadata }
            }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let dataTask = session.dataTask(with: try #require(response.url))

        let disposition = await withCheckedContinuation { continuation in
            delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
                continuation.resume(returning: disposition)
            }
        }
        #expect(disposition == .allow)
        return delivered.withLock { $0 }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "OpenCastDownloadInfrastructureTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
