@preconcurrency import AVFoundation
import Foundation

nonisolated final class StreamingAudioResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let originalURL: URL

    private let episodeID: String
    private let podcastID: String?
    private let cache: StreamingAudioDiskCache
    private let fetcher: any StreamingAudioHTTPRangeFetching
    private let byteBudget: Int64
    private let queue: DispatchQueue
    private let taskRegistry = StreamingAudioTaskRegistry()

    init(
        episodeID: String,
        podcastID: String?,
        originalURL: URL,
        cache: StreamingAudioDiskCache,
        fetcher: any StreamingAudioHTTPRangeFetching = URLSessionStreamingAudioRangeFetcher(),
        byteBudget: Int64 = StreamingAudioCacheConfiguration.defaultByteBudget,
        queue: DispatchQueue = DispatchQueue(label: "OpenCastPlayback.StreamingAudioResourceLoader")
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.originalURL = originalURL
        self.cache = cache
        self.fetcher = fetcher
        self.byteBudget = byteBudget
        self.queue = queue
    }

    func install(on asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func cancelAll() {
        taskRegistry.cancelAll()
    }

    func markCompleted() {
        Task { [episodeID, originalURL, cache] in
            try? await cache.markCompleted(episodeID: episodeID, originalURL: originalURL)
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let range = requestedRange(from: loadingRequest) else {
            loadingRequest.finishLoading(with: StreamingAudioCacheError.invalidRange)
            return false
        }

        let id = ObjectIdentifier(loadingRequest)
        let requestBox = StreamingAudioLoadingRequestBox(request: loadingRequest, queue: queue)
        taskRegistry.reserve(id)
        let task = Task { [episodeID, podcastID, originalURL, cache, fetcher, byteBudget, requestBox] in
            defer {
                self.taskRegistry.remove(id)
            }

            do {
                let response = try await Self.load(
                    episodeID: episodeID,
                    podcastID: podcastID,
                    originalURL: originalURL,
                    range: range,
                    cache: cache,
                    fetcher: fetcher,
                    byteBudget: byteBudget
                )
                try Task.checkCancellation()
                requestBox.finish(with: .success(response))
            } catch is CancellationError {
                requestBox.finish(with: .failure(CancellationError()))
            } catch {
                requestBox.finish(with: .failure(error))
            }
        }
        taskRegistry.install(task, for: id)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let id = ObjectIdentifier(loadingRequest)
        taskRegistry.cancel(id)
    }

    private func requestedRange(from loadingRequest: AVAssetResourceLoadingRequest) -> Range<Int64>? {
        guard let dataRequest = loadingRequest.dataRequest else {
            return 0..<1
        }

        let requestedOffset = dataRequest.currentOffset != 0
            ? dataRequest.currentOffset
            : dataRequest.requestedOffset
        let requestedLength = max(dataRequest.requestedLength, 1)
        guard requestedOffset >= 0 else {
            return nil
        }

        return requestedOffset..<(requestedOffset + Int64(requestedLength))
    }

    @concurrent
    private static func load(
        episodeID: String,
        podcastID: String?,
        originalURL: URL,
        range: Range<Int64>,
        cache: StreamingAudioDiskCache,
        fetcher: any StreamingAudioHTTPRangeFetching,
        byteBudget: Int64
    ) async throws -> StreamingAudioLoadingResponse {
        if let cachedResponse = try await cache.cachedResponse(
            episodeID: episodeID,
            originalURL: originalURL,
            range: range
        ) {
            return StreamingAudioLoadingResponse(
                data: cachedResponse.data,
                contentLength: cachedResponse.contentLength,
                mimeType: cachedResponse.mimeType
            )
        }

        let fetched = try await fetcher.data(for: originalURL, range: range)
        let manifest = try await cache.store(
            fetched,
            episodeID: episodeID,
            podcastID: podcastID,
            originalURL: originalURL
        )
        await cache.schedulePrune(byteBudget: byteBudget)
        return StreamingAudioLoadingResponse(
            data: fetched.data,
            contentLength: manifest.contentLength,
            mimeType: manifest.mimeType
        )
    }
}
