import Foundation
import ImageIO
import OpenCastCore
import SwiftUI

typealias ArtworkDataLoader = @Sendable (URLRequest) async throws -> ArtworkDataResponse
typealias ArtworkImageDecoder = @Sendable (_ data: Data, _ targetPixelSize: CGSize) -> UIImage?

actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private nonisolated let memoryCache: ArtworkMemoryCache
    private let diskCache: ArtworkDiskCache
    private let dataLoader: ArtworkDataLoader
    private let imageDecoder: ArtworkImageDecoder
    private var inFlightLoads: [String: (id: UUID, task: Task<ArtworkDataResponse?, Error>)] = [:]
    private var revalidationTasks: [String: Task<Void, Never>] = [:]

    init(
        countLimit: Int = 200,
        totalCostLimit: Int = 48 * 1_024 * 1_024,
        memoryCache: ArtworkMemoryCache? = nil,
        diskCache: ArtworkDiskCache? = nil,
        httpClient: any OpenCastHTTPClient = URLSessionOpenCastHTTPClient(
            configuration: OpenCastURLSessionFactory.sharedConfiguration(
                cacheDirectory: OpenCastCacheController.defaultHTTPCacheDirectory()
            )
        ),
        dataLoader: ArtworkDataLoader? = nil,
        imageDecoder: ArtworkImageDecoder? = nil
    ) {
        self.memoryCache = memoryCache ?? ArtworkMemoryCache(
            countLimit: countLimit,
            totalCostLimit: totalCostLimit
        )
        self.diskCache = diskCache ?? ArtworkDiskCache()
        self.dataLoader = dataLoader ?? Self.dataLoader(httpClient: httpClient)
        self.imageDecoder = imageDecoder ?? Self.downsampleImage
    }

    nonisolated func cachedImage(for request: ArtworkRequest) -> UIImage? {
        memoryCache.image(for: request)
    }

    nonisolated func bestCachedImage(for request: ArtworkRequest) -> UIImage? {
        memoryCache.bestImage(for: request)
    }

    nonisolated func removeCachedImages() {
        memoryCache.removeAll()
    }

    func image(
        for artworkURL: URL,
        targetPixelSize: CGSize,
        cacheKind: ArtworkCacheKind = .show
    ) async throws -> UIImage? {
        try await loadResult(
            for: ArtworkRequest(url: artworkURL, targetPixelSize: targetPixelSize),
            cacheKind: cacheKind
        )?.image
    }

    func image(for request: ArtworkRequest, cacheKind: ArtworkCacheKind = .show) async throws -> UIImage? {
        try await loadResult(for: request, cacheKind: cacheKind)?.image
    }

    func loadResult(for request: ArtworkRequest, cacheKind: ArtworkCacheKind = .show) async throws -> ArtworkLoadResult? {
        try Task.checkCancellation()

        if let cachedImage = memoryCache.image(for: request) {
            let preview = await cachedOrBackfilledPreview(for: request)
            await scheduleRevalidationIfNeeded(for: request.url, cacheKind: cacheKind)
            return ArtworkLoadResult(image: cachedImage, preview: preview)
        }

        if let diskEntry = try await diskCache.cachedEntry(for: request.url) {
            if let image = await Self.decodeImage(
                data: diskEntry.data,
                targetPixelSize: request.pixelSize,
                imageDecoder: imageDecoder
            ) {
                memoryCache.insert(image, for: request)
                let preview = await preview(for: diskEntry, request: request)
                if diskEntry.metadata.isStale(for: cacheKind) {
                    scheduleRevalidation(for: request.url, metadata: diskEntry.metadata)
                }
                return ArtworkLoadResult(image: image, preview: preview)
            }

            try? await diskCache.remove(for: request.url)
        }

        let inFlightLoad = task(for: request.url)
        let canonicalURLString = request.imageKey

        do {
            guard let response = try await inFlightLoad.task.value else {
                finishLoad(inFlightLoad.id, for: canonicalURLString)
                return nil
            }
            let image = await Self.decodeImage(
                data: response.data,
                targetPixelSize: request.pixelSize,
                imageDecoder: imageDecoder
            )
            if let image {
                let preview = await ArtworkPreviewGenerator.generate(
                    from: response.data,
                    canonicalArtworkURLKey: request.imageKey
                )
                _ = try await diskCache.store(
                    data: response.data,
                    response: response.response,
                    for: request.url,
                    preview: preview
                )
                memoryCache.insert(image, for: request)
                finishLoad(inFlightLoad.id, for: canonicalURLString)
                try Task.checkCancellation()
                return ArtworkLoadResult(image: image, preview: preview)
            }
            finishLoad(inFlightLoad.id, for: canonicalURLString)
            try Task.checkCancellation()
            return nil
        } catch is CancellationError {
            if !Task.isCancelled || inFlightLoad.task.isCancelled {
                finishLoad(inFlightLoad.id, for: canonicalURLString)
            }
            throw CancellationError()
        } catch {
            finishLoad(inFlightLoad.id, for: canonicalURLString)
            throw error
        }
    }

    func waitForBackgroundRevalidations() async {
        let tasks = Array(revalidationTasks.values)
        for task in tasks {
            await task.value
        }
    }

    private func cachedOrBackfilledPreview(for request: ArtworkRequest) async -> ArtworkPreview? {
        guard let diskEntry = try? await diskCache.cachedEntry(for: request.url) else {
            return nil
        }

        return await preview(for: diskEntry, request: request)
    }

    private func preview(
        for diskEntry: ArtworkDiskCacheEntry,
        request: ArtworkRequest
    ) async -> ArtworkPreview? {
        if let preview = diskEntry.metadata.preview {
            return preview
        }

        guard let preview = await ArtworkPreviewGenerator.generate(
            from: diskEntry.data,
            canonicalArtworkURLKey: diskEntry.metadata.canonicalURL
        ) else {
            return nil
        }

        do {
            try await diskCache.updatePreview(preview, for: request.url)
        } catch {
            // Ignore preview update errors; preview is an optional optimization
        }
        return preview
    }

    private func task(for artworkURL: URL) -> (id: UUID, task: Task<ArtworkDataResponse?, Error>) {
        let canonicalURLString = URLCanonicalizer.canonicalString(for: artworkURL)
        if let inFlightLoad = inFlightLoads[canonicalURLString] {
            return inFlightLoad
        }

        let dataLoader = dataLoader
        let task = Task {
            try await Self.loadArtworkData(from: artworkURL, validatorHeaderFields: [:], dataLoader: dataLoader)
        }
        let inFlightLoad = (id: UUID(), task: task)
        inFlightLoads[canonicalURLString] = inFlightLoad
        return inFlightLoad
    }

    private func finishLoad(_ id: UUID, for canonicalURLString: String) {
        // A request can be restarted while an older finisher is still unwinding.
        guard inFlightLoads[canonicalURLString]?.id == id else {
            return
        }

        inFlightLoads[canonicalURLString] = nil
    }

    private func scheduleRevalidationIfNeeded(for artworkURL: URL, cacheKind: ArtworkCacheKind) async {
        let canonicalURLString = URLCanonicalizer.canonicalString(for: artworkURL)
        guard revalidationTasks[canonicalURLString] == nil else {
            return
        }

        guard let metadata = try? await diskCache.metadata(for: artworkURL),
              metadata.isStale(for: cacheKind)
        else {
            return
        }

        scheduleRevalidation(for: artworkURL, metadata: metadata)
    }

    private func scheduleRevalidation(for artworkURL: URL, metadata: ArtworkDiskCacheMetadata) {
        guard metadata.hasValidator,
              revalidationTasks[metadata.canonicalURL] == nil
        else {
            return
        }

        let dataLoader = dataLoader
        let diskCache = diskCache
        let imageDecoder = imageDecoder
        let task = Task { [weak self, metadata] in
            do {
                let response = try await Self.loadArtworkData(
                    from: artworkURL,
                    validatorHeaderFields: metadata.validatorHeaderFields,
                    dataLoader: dataLoader
                )
                if let response {
                    if response.response.statusCode == 304 {
                        try await diskCache.updateValidation(for: artworkURL, response: response.response)
                    } else {
                        let canStore = await Self.canStoreRevalidatedArtwork(
                            response: response,
                            imageDecoder: imageDecoder
                        )
                        if canStore {
                            let preview = await ArtworkPreviewGenerator.generate(
                                from: response.data,
                                canonicalArtworkURLKey: metadata.canonicalURL
                            )
                            _ = try await diskCache.store(
                                data: response.data,
                                response: response.response,
                                for: artworkURL,
                                preview: preview
                            )
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
            }

            await self?.finishRevalidation(for: metadata.canonicalURL)
        }
        revalidationTasks[metadata.canonicalURL] = task
    }

    @concurrent
    private static func canStoreRevalidatedArtwork(
        response: ArtworkDataResponse,
        imageDecoder: ArtworkImageDecoder
    ) async -> Bool {
        guard response.response.statusCode.map({ (200..<300).contains($0) }) != false,
              response.response.headerValue("etag") != nil
                || response.response.headerValue("last-modified") != nil
        else {
            return false
        }

        return imageDecoder(response.data, CGSize(width: 1, height: 1)) != nil
    }

    private func finishRevalidation(for canonicalURLString: String) {
        revalidationTasks[canonicalURLString] = nil
    }

    @concurrent
    private static func loadArtworkData(
        from artworkURL: URL,
        validatorHeaderFields: [String: String],
        dataLoader: ArtworkDataLoader
    ) async throws -> ArtworkDataResponse? {
        try Task.checkCancellation()
        var request = URLRequest(
            url: artworkURL,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 15
        )
        for (name, value) in validatorHeaderFields {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let response = try await dataLoader(request)
        try Task.checkCancellation()

        if response.response.statusCode == 304 {
            return response
        }

        if response.response.statusCode.map({ (200..<300).contains($0) }) == false {
            return nil
        }

        return response
    }

    @concurrent
    private static func loadData(
        for request: URLRequest,
        httpClient: any OpenCastHTTPClient
    ) async throws -> ArtworkDataResponse {
        guard let artworkURL = request.url else {
            throw URLError(.badURL)
        }

        if artworkURL.isFileURL {
            let data = try Data(contentsOf: artworkURL)
            return ArtworkDataResponse(
                data: data,
                response: OpenCastHTTPResponse(
                    url: artworkURL,
                    mimeType: nil,
                    expectedContentLength: Int64(data.count),
                    statusCode: nil,
                    headers: [:]
                )
            )
        }

        let result = try await httpClient.data(for: request)
        return ArtworkDataResponse(data: result.data, response: result.response)
    }

    private nonisolated static func dataLoader(httpClient: any OpenCastHTTPClient) -> ArtworkDataLoader {
        { request in
            try await loadData(for: request, httpClient: httpClient)
        }
    }

    @concurrent
    private static func decodeImage(
        data: Data,
        targetPixelSize: CGSize,
        imageDecoder: ArtworkImageDecoder
    ) async -> UIImage? {
        imageDecoder(data, targetPixelSize)
    }

    private nonisolated static func downsampleImage(data: Data, targetPixelSize: CGSize) -> UIImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let maxPixelSize = max(Int(max(targetPixelSize.width, targetPixelSize.height).rounded(.up)), 1)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

}
