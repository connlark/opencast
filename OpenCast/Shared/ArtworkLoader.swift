import Foundation
import ImageIO
import OpenCastCore
import SwiftUI

typealias ArtworkDataLoader = @Sendable (URLRequest) async throws -> ArtworkDataResponse
typealias ArtworkSourceHasher = @Sendable (Data) async -> String
typealias ArtworkPreviewBuilder = @Sendable (Data, String, String) async -> ArtworkPreview?
typealias ArtworkImageDecoder = @Sendable (_ data: Data, _ targetPixelSize: CGSize) -> UIImage?

actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private nonisolated let memoryCache: ArtworkMemoryCache
    private let diskCache: ArtworkDiskCache
    private let dataLoader: ArtworkDataLoader
    private let imageDecoder: ArtworkImageDecoder
    private let sourceHasher: ArtworkSourceHasher
    private let previewBuilder: ArtworkPreviewBuilder
    private var inFlightLoads: [String: (id: UUID, task: Task<ArtworkSource?, Error>, readers: Int)] = [:]
    private var inFlightPreviews: [String: (id: UUID, task: Task<ArtworkPreview?, Never>)] = [:]
    private var sourcePreviews: [String: ArtworkPreview] = [:]
    private var previewOrder: [String] = []
    private var inFlightDecodes: [String: Task<UIImage?, Never>] = [:]
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
        imageDecoder: ArtworkImageDecoder? = nil,
        sourceHasher: ArtworkSourceHasher? = nil,
        previewBuilder: ArtworkPreviewBuilder? = nil
    ) {
        self.memoryCache = memoryCache ?? ArtworkMemoryCache(
            countLimit: countLimit,
            totalCostLimit: totalCostLimit
        )
        self.diskCache = diskCache ?? ArtworkDiskCache()
        self.dataLoader = dataLoader ?? Self.dataLoader(httpClient: httpClient)
        self.imageDecoder = imageDecoder ?? Self.downsampleImage
        self.sourceHasher = sourceHasher ?? Self.sourceHash
        self.previewBuilder = previewBuilder ?? { data, sourceHash, key in
            await ArtworkPreviewGenerator.generate(from: data, sourceHash: sourceHash, canonicalArtworkURLKey: key)
        }
    }

    nonisolated func cachedImage(for request: ArtworkRequest) -> UIImage? {
        memoryCache.image(for: request)
    }

    nonisolated func bestCachedImage(for request: ArtworkRequest) -> UIImage? {
        memoryCache.bestImage(for: request)
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

        if inFlightLoads[request.imageKey] == nil,
           memoryCache.image(for: request) != nil,
           let metadata = try? await diskCache.metadata(for: request.url),
           let preview = metadata.preview,
           let image = memoryCache.image(forContentKey: DecodedArtwork.contentKey(for: request, sourceHash: preview.sourceHash)) {
            memoryCache.alias(request, toContentKey: DecodedArtwork.contentKey(for: request, sourceHash: preview.sourceHash))
            if metadata.isStale(for: cacheKind) {
                scheduleRevalidation(for: request.url, metadata: metadata)
            }
            return ArtworkLoadResult(image: image, preview: preview)
        }

        // Coalesce the entire source operation, including hashing, preview and
        // disk publication. A late caller cannot observe an image-only result.
        let load = task(for: request)
        defer { finishLoad(load.id, for: request.imageKey) }
        guard let source = try await load.task.value else {
            try Task.checkCancellation()
            return nil
        }
        let contentKey = DecodedArtwork.contentKey(for: request, sourceHash: source.sourceHash)
        let decoded: DecodedArtwork?
        if source.firstDecode.contentKey == contentKey {
            decoded = source.firstDecode
        } else {
            decoded = await decodedArtwork(for: request, data: source.data, sourceHash: source.sourceHash)
        }
        if let decoded {
            memoryCache.alias(request, toContentKey: decoded.contentKey)
        }
        try Task.checkCancellation()
        guard let decoded else { return nil }
        if source.metadata.isStale(for: cacheKind) {
            scheduleRevalidation(for: request.url, metadata: source.metadata)
        }
        return ArtworkLoadResult(image: decoded.image, preview: source.metadata.preview)
    }

    func waitForBackgroundRevalidations() async {
        let tasks = Array(revalidationTasks.values)
        for task in tasks {
            await task.value
        }
    }

    private func loadSource(for request: ArtworkRequest) async throws -> ArtworkSource? {
        if let entry = try await diskCache.cachedEntry(for: request.url) {
            let hash = await sourceHasher(entry.data)
            if let decoded = await decodedArtwork(for: request, data: entry.data, sourceHash: hash) {
                var metadata = entry.metadata
                if metadata.preview?.sourceHash != hash {
                    metadata.preview = await sharedPreview(data: entry.data, sourceHash: hash, key: request.imageKey)
                    if let preview = metadata.preview {
                        // Revalidation may replace the bytes while the preview
                        // is generated. Never attach an old preview to new data.
                        _ = try? await diskCache.updatePreview(preview, for: request.url, matchingData: entry.data)
                    }
                } else if let preview = metadata.preview {
                    rememberPreview(preview)
                }
                return ArtworkSource(data: entry.data, sourceHash: hash, metadata: metadata, firstDecode: decoded)
            }
            try? await diskCache.remove(for: request.url)
        }

        guard let response = try await Self.loadArtworkData(
            from: request.url, validatorHeaderFields: [:], dataLoader: dataLoader
        ) else { return nil }
        let hash = await sourceHasher(response.data)
        guard let decoded = await decodedArtwork(for: request, data: response.data, sourceHash: hash) else { return nil }
        let preview = await sharedPreview(data: response.data, sourceHash: hash, key: request.imageKey)
        let metadata = try await diskCache.store(
            data: response.data, response: response.response, for: request.url, preview: preview
        )
        return ArtworkSource(data: response.data, sourceHash: hash, metadata: metadata, firstDecode: decoded)
    }

    private func sharedPreview(data: Data, sourceHash: String, key: String) async -> ArtworkPreview? {
        if var preview = sourcePreviews[sourceHash] {
            preview.canonicalArtworkURLKey = key
            return preview
        }
        let load: (id: UUID, task: Task<ArtworkPreview?, Never>)
        if let existing = inFlightPreviews[sourceHash] {
            load = existing
        } else {
            let builder = previewBuilder
            load = (UUID(), Task { await builder(data, sourceHash, key) })
            inFlightPreviews[sourceHash] = load
        }
        defer {
            if inFlightPreviews[sourceHash]?.id == load.id {
                inFlightPreviews[sourceHash] = nil
            }
        }
        guard var preview = await load.task.value else { return nil }
        rememberPreview(preview)
        preview.canonicalArtworkURLKey = key
        return preview
    }

    private func rememberPreview(_ preview: ArtworkPreview) {
        if sourcePreviews[preview.sourceHash] == nil {
            // Only tiny RGB grids are retained here; original bytes and decoded
            // display images keep their existing cache lifetimes.
            if previewOrder.count == 200 {
                sourcePreviews[previewOrder.removeFirst()] = nil
            }
            previewOrder.append(preview.sourceHash)
        }
        sourcePreviews[preview.sourceHash] = preview
    }

    private func decodedArtwork(for request: ArtworkRequest, data: Data, sourceHash: String) async -> DecodedArtwork? {
        let contentKey = DecodedArtwork.contentKey(for: request, sourceHash: sourceHash)
        if let image = memoryCache.image(forContentKey: contentKey) {
            return DecodedArtwork(image: image, contentKey: contentKey, sourceHash: sourceHash)
        }
        let image: UIImage?
        if let task = inFlightDecodes[contentKey] {
            image = await task.value
        } else {
            let imageDecoder = imageDecoder
            let memoryCache = memoryCache
            let task = Task {
                let image = await Self.decodeImage(data: data, targetPixelSize: request.pixelSize, imageDecoder: imageDecoder)
                if let image { memoryCache.store(image, forContentKey: contentKey) }
                return image
            }
            inFlightDecodes[contentKey] = task
            image = await task.value
            inFlightDecodes[contentKey] = nil
        }
        guard let image else { return nil }
        return DecodedArtwork(image: image, contentKey: contentKey, sourceHash: sourceHash)
    }

    @concurrent
    private static func sourceHash(for data: Data) async -> String {
        ArtworkPreviewGenerator.sourceHash(for: data)
    }

    private func task(for request: ArtworkRequest) -> (id: UUID, task: Task<ArtworkSource?, Error>) {
        if var existing = inFlightLoads[request.imageKey] {
            existing.readers += 1
            inFlightLoads[request.imageKey] = existing
            return (existing.id, existing.task)
        }
        let task = Task { try await loadSource(for: request) }
        let load = (id: UUID(), task: task)
        inFlightLoads[request.imageKey] = (load.id, load.task, 1)
        return load
    }

    private func finishLoad(_ id: UUID, for key: String) {
        guard var load = inFlightLoads[key], load.id == id else { return }
        load.readers -= 1
        inFlightLoads[key] = load.readers == 0 ? nil : load
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

        // Admission policy on receive: oversized payloads never reach decode
        // or either cache (security triage P1 #4).
        guard ArtworkTransferPolicy.admitsByteCount(response.data.count) else {
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

        // Header-only dimension read; refuses extreme canvases before any
        // pixel work (security triage P1 #4).
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any] {
            guard ArtworkTransferPolicy.admitsPixelDimensions(
                width: properties[kCGImagePropertyPixelWidth] as? Int,
                height: properties[kCGImagePropertyPixelHeight] as? Int
            ) else {
                return nil
            }
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
