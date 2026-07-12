// Originally from: https://github.com/huggingface/swift-transformers
// Version: 1.1.6 (commit: 573e5c9036c2f136b3a8a071da8e8907322403d0)
// License: Apache 2.0 (https://github.com/huggingface/swift-transformers/blob/main/LICENSE)
// Copyright 2022 Hugging Face SAS
// Modified by Argmax, Inc. and OpenCast.

import Foundation

struct HubApi: Sendable {
    var downloadBase: URL
    var hfToken: String?
    var endpoint: String
    var useBackgroundSession: Bool
    var useOfflineMode: Bool?

    init(
        downloadBase: URL? = nil,
        hfToken: String? = nil,
        endpoint: String? = nil,
        useBackgroundSession: Bool = false,
        useOfflineMode: Bool? = nil
    ) {
        if let downloadBase {
            self.downloadBase = downloadBase
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.downloadBase = documents.appending(component: "huggingface")
        }
        self.hfToken = hfToken
        self.endpoint = endpoint ?? "https://huggingface.co"
        self.useBackgroundSession = useBackgroundSession
        self.useOfflineMode = useOfflineMode
    }

    static let shared = HubApi()
}

extension HubApi {
    func configuration(from filename: String, in repo: Repo) throws -> Config {
        let fileURL = localRepoLocation(repo).appending(path: filename)
        return try configuration(fileURL: fileURL)
    }

    func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        guard let parsed = try? JSONSerialization.bomPreservingJsonObject(with: data) else {
            throw Hub.HubClientError.jsonSerialization(
                fileURL: fileURL,
                message: "JSON serialization failed for \(fileURL)."
            )
        }
        guard let dictionary = parsed as? [NSString: Any] else {
            throw Hub.HubClientError.parse
        }
        return Config(dictionary)
    }
}

extension HubApi {
    func localRepoLocation(_ repo: Repo) -> URL {
        downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)
    }

    @available(*, unavailable, message: "OpenCast bundles Whisper assets locally and disables remote Hub file listing.")
    func getFilenames(from repo: Repo, revision: String = "main", matching globs: [String] = []) async throws -> [String] {
        throw Hub.HubClientError.downloadError("Remote Hub file listing is disabled in OpenCast.")
    }

    @available(*, unavailable, message: "OpenCast bundles Whisper assets locally and disables remote Hub snapshots.")
    func snapshot(
        from repo: Repo,
        revision: String = "main",
        matching globs: [String] = [],
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        throw Hub.HubClientError.downloadError("Remote Hub snapshots are disabled in OpenCast.")
    }
}
