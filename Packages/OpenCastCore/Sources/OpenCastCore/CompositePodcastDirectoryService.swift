import Foundation

/// Queries Apple and Podcast Index concurrently and merges through
/// `DirectoryResultMerger`. Apple is the ranking authority; either
/// provider alone carries the results when the other fails, and the
/// search errors only when both fail (Apple's error surfaces).
public struct CompositePodcastDirectoryService: PodcastDirectoryService {
    public static let defaultProviderTimeout: Duration = .seconds(10)

    let apple: any PodcastDirectoryService
    let podcastIndex: any PodcastDirectoryService
    let providerTimeout: Duration

    public init(
        apple: any PodcastDirectoryService,
        podcastIndex: any PodcastDirectoryService,
        providerTimeout: Duration = CompositePodcastDirectoryService.defaultProviderTimeout
    ) {
        self.apple = apple
        self.podcastIndex = podcastIndex
        self.providerTimeout = providerTimeout
    }

    public func search(query: String) async throws -> [DirectoryPodcastResult] {
        let apple = apple
        let podcastIndex = podcastIndex
        let timeout = providerTimeout
        async let appleAttempt = Self.attempt(timeout: timeout) {
            try await apple.search(query: query)
        }
        async let podcastIndexAttempt = Self.attempt(timeout: timeout) {
            try await podcastIndex.search(query: query)
        }

        switch (await appleAttempt, await podcastIndexAttempt) {
        case (.success(let appleResults), .success(let podcastIndexResults)):
            return DirectoryResultMerger.merge(
                appleResults: appleResults,
                podcastIndexResults: podcastIndexResults
            )
        case (.success(let appleResults), .failure):
            return appleResults
        case (.failure, .success(let podcastIndexResults)):
            return podcastIndexResults
        case (.failure(let appleError), .failure):
            throw appleError
        }
    }

    public func lookup(appleID: Int) async throws -> DirectoryPodcastResult? {
        let podcastIndex = podcastIndex
        return try await Self.withTimeout(providerTimeout) {
            try await podcastIndex.lookup(appleID: appleID)
        }
    }

    private static func attempt(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> [DirectoryPodcastResult]
    ) async -> Result<[DirectoryPodcastResult], any Error> {
        do {
            return .success(try await withTimeout(timeout, operation: operation))
        } catch {
            return .failure(error)
        }
    }

    private static func withTimeout<Value: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DirectoryProviderTimeoutError()
            }
            defer {
                group.cancelAll()
            }
            guard let first = try await group.next() else {
                throw DirectoryProviderTimeoutError()
            }
            return first
        }
    }
}

public struct DirectoryProviderTimeoutError: Error, Equatable {
    public init() {}
}
