//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2026 Argmax, Inc. All rights reserved.

import Foundation

// MARK: - Public HubApiWrapper

/// Local Hub-compatible path helper used by the vendored tokenizer parser.
///
/// OpenCast bundles Whisper models and tokenizers as app resources. Remote Hub
/// APIs are intentionally unavailable in this vendored target.
public struct HubApiWrapper: Sendable {
    private let impl: HubApi

    /// Provides access to the underlying HubApi for same-module callers (e.g., Hub.swift, Tokenizer.swift).
    var hubApi: HubApi { impl }

    /// Creates a local Hub-compatible helper.
    ///
    /// - Parameters:
    ///   - downloadBase: Base directory for cached downloads (defaults to Documents/huggingface)
    ///   - hfToken: Ignored; retained for source compatibility.
    ///   - endpoint: Ignored; retained for source compatibility.
    ///   - useBackgroundSession: Ignored; retained for source compatibility.
    public init(
        downloadBase: URL? = nil,
        hfToken: String? = nil,
        endpoint: String? = nil,
        useBackgroundSession: Bool = false
    ) {
        impl = HubApi(
            downloadBase: downloadBase,
            hfToken: hfToken,
            endpoint: endpoint,
            useBackgroundSession: useBackgroundSession
        )
    }

    /// Shared client with default configuration.
    public static let shared = HubApiWrapper()

    /// The type of Hugging Face repository.
    public enum RepoType: String, Codable, Sendable {
        /// Model repositories (e.g. argmaxinc/whisperkit-coreml).
        case models
        /// Dataset repositories used for evaluation and regression testing.
        case datasets
        case spaces
    }

    /// A reference to a repository on the Hugging Face Hub.
    public struct Repo: Codable, Sendable, Hashable {
        /// Repository identifier (e.g. "argmaxinc/whisperkit-coreml").
        public let id: String
        /// Repository type.
        public let type: RepoType

        /// - Parameters:
        ///   - id: Repository identifier
        ///   - type: Repository type (defaults to .models)
        public init(id: String, type: RepoType = .models) {
            self.id = id
            self.type = type
        }
    }

    /// Remote snapshots are unavailable in OpenCast's vendored runtime.
    @available(*, unavailable, message: "OpenCast bundles Whisper assets locally and disables remote Hub snapshots.")
    public func snapshot(
        from repo: Repo,
        revision: String = "main",
        matching globs: [String] = [],
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        throw Hub.HubClientError.downloadError("Remote Hub snapshots are disabled in OpenCast.")
    }

    /// Remote file listing is unavailable in OpenCast's vendored runtime.
    @available(*, unavailable, message: "OpenCast bundles Whisper assets locally and disables remote Hub file listing.")
    public func getFilenames(
        from repo: Repo,
        revision: String = "main",
        matching globs: [String] = []
    ) async throws -> [String] {
        throw Hub.HubClientError.downloadError("Remote Hub file listing is disabled in OpenCast.")
    }

    /// Returns the local cache directory for a repository.
    ///
    /// - Parameter repo: The repository to locate
    /// - Returns: Local directory URL under the download base (may not exist yet)
    public func localRepoLocation(_ repo: Repo) -> URL {
        impl.localRepoLocation(repo.asHubApiRepo)
    }
}

// MARK: - Internal bridge

// HubApi.Repo and HubApi.RepoType are defined here as internal nested types so that
// HubApi.swift method signatures (snapshot, getFilenames, localRepoLocation, etc.) can
// reference `Repo` unqualified without change. The asHubApiRepo bridge below converts
// the public HubApiWrapper.Repo into HubApi.Repo when forwarding calls to the impl.
extension HubApi {
    enum RepoType: String, Codable, Sendable {
        case models
        case datasets
        case spaces
    }

    struct Repo: Codable, Sendable, Hashable {
        let id: String
        let type: RepoType

        init(id: String, type: RepoType = .models) {
            self.id = id
            self.type = type
        }
    }
}

extension HubApiWrapper.Repo {
    /// Converts to the internal HubApi.Repo type for passing to HubApi methods.
    var asHubApiRepo: HubApi.Repo {
        let repoType: HubApi.RepoType
        switch type {
            case .models: repoType = .models
            case .datasets: repoType = .datasets
            case .spaces: repoType = .spaces
        }
        return HubApi.Repo(id: id, type: repoType)
    }
}
