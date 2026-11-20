import Foundation
import Observation
import OpenCastCore

@Observable
final class HelpContentStore {
    static let refreshInterval: TimeInterval = 60 * 60
    static let maximumDocumentByteCount = 256 * 1_024
    nonisolated static let bundledResourceName = "HelpContent"
    nonisolated static let cachedDocumentFileName = "help-v1.json"

    private(set) var document: HelpDocument
    private(set) var loadErrorMessage: String?
    private(set) var lastRefreshErrorMessage: String?

    @ObservationIgnored private let configuration: HelpContentBackendConfiguration
    @ObservationIgnored private let httpClient: any OpenCastHTTPClient
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let currentBuild: Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var hasLoadedCachedDocument = false
    @ObservationIgnored private var lastRefreshAttempt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        configuration: HelpContentBackendConfiguration = .current,
        httpClient: any OpenCastHTTPClient,
        cacheDirectory: URL,
        bundle: Bundle = .main,
        currentBuild: Int = OpenCastAppVersion.buildNumber ?? 0,
        now: @escaping () -> Date = { .now }
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.cacheDirectory = cacheDirectory
        self.currentBuild = currentBuild
        self.now = now
        do {
            document = try Self.loadBundledDocument(from: bundle)
        } catch {
            document = .empty
            loadErrorMessage = error.localizedDescription
        }
    }

    var visibleTopics: [HelpTopic] {
        document.topics.filter { ($0.minAppBuild ?? 0) <= currentBuild }
    }

    func topic(_ id: String) -> HelpTopic? {
        visibleTopics.first { $0.id == id }
    }

    func refreshIfNeeded() async {
        if !hasLoadedCachedDocument {
            hasLoadedCachedDocument = true
            await adoptCachedDocument()
        }

        guard configuration.isEnabled else {
            return
        }

        if let refreshTask {
            await refreshTask.value
            return
        }

        if let lastRefreshAttempt, now().timeIntervalSince(lastRefreshAttempt) < Self.refreshInterval {
            return
        }

        lastRefreshAttempt = now()
        // Unstructured so the shared refresh outlives any one caller's cancellation.
        let task = Task {
            await refreshFromNetwork()
        }
        refreshTask = task
        await task.value
        if refreshTask == task {
            refreshTask = nil
        }
    }

    private var cachedDocumentURL: URL {
        cacheDirectory.appending(path: Self.cachedDocumentFileName)
    }

    private func adoptCachedDocument() async {
        do {
            guard let data = try await Self.readCachedDocument(at: cachedDocumentURL) else {
                return
            }
            adoptIfNewer(try await Self.decodeDocument(data))
        } catch is CancellationError {
        } catch {
            lastRefreshErrorMessage = error.localizedDescription
        }
    }

    private func refreshFromNetwork() async {
        do {
            var request = URLRequest(url: configuration.documentURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let result = try await httpClient.data(
                for: request,
                maximumBodyByteCount: Self.maximumDocumentByteCount
            )
            if let statusCode = result.response.statusCode, !(200..<300).contains(statusCode) {
                throw HelpContentError.httpStatus(statusCode)
            }
            let remote = try await Self.decodeDocument(result.data)
            if adoptIfNewer(remote) {
                try await Self.writeCachedDocument(result.data, to: cachedDocumentURL)
            }
            lastRefreshErrorMessage = nil
        } catch is CancellationError {
        } catch {
            lastRefreshErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func adoptIfNewer(_ candidate: HelpDocument) -> Bool {
        guard candidate.schemaVersion == HelpDocument.supportedSchemaVersion,
              candidate.updatedAt > document.updatedAt
        else {
            return false
        }
        document = candidate
        return true
    }

    private nonisolated static func loadBundledDocument(from bundle: Bundle) throws -> HelpDocument {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json") else {
            throw HelpContentError.missingBundledDocument
        }
        let document = try HelpDocument.decode(try Data(contentsOf: url))
        guard document.schemaVersion == HelpDocument.supportedSchemaVersion else {
            throw HelpContentError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    @concurrent
    private static func decodeDocument(_ data: Data) async throws -> HelpDocument {
        try HelpDocument.decode(data)
    }

    @concurrent
    private static func readCachedDocument(at url: URL) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    @concurrent
    private static func writeCachedDocument(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
