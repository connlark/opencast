import Foundation
import OpenCastAnalysis

/// Builds request URLs from a bundle endpoint, refusing anything that would
/// send the key off the provider's pinned host.
struct AnalysisProviderURLs: Sendable {
    let provider: AnalysisProvider
    let endpoint: AnalysisProviderEndpoint

    init(provider: AnalysisProvider, endpoint: AnalysisProviderEndpoint) throws(AnalysisProviderConfigurationError) {
        guard Self.pinnedHost(endpoint.baseURL) == provider.pinnedHost,
              Self.isSafePath(endpoint.generatePath), Self.isSafePath(endpoint.countTokensPath)
        else {
            throw .unpinnedEndpoint
        }
        let expected: AnalysisProviderEndpoint.Auth = provider == .google ? .googleAPIKey : .bearer
        guard endpoint.auth == expected else { throw .wrongAuthentication }
        self.provider = provider
        self.endpoint = endpoint
    }

    /// `baseURL + path` with `{model}` replaced, or `nil` when the model id
    /// is not 1-128 of `[A-Za-z0-9._-]` or the result leaves the pinned host.
    func url(path: String, modelID: String?) -> URL? {
        var resolved = path
        if path.contains("{model}") {
            guard let modelID, Self.isValidModelID(modelID) else { return nil }
            resolved = path.replacing("{model}", with: modelID)
        }
        var base = endpoint.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard Self.isSafePath(resolved),
              let url = URL(string: base + resolved),
              Self.pinnedHost(url) == provider.pinnedHost
        else {
            return nil
        }
        return url
    }

    /// The constant headers the bundle adds, minus any that would replace
    /// the credential or the content type.
    var versionHeaders: [AnalysisHTTPHeader] {
        let reserved: Set<String> = ["authorization", "x-goog-api-key", "x-api-key", "content-type", "cookie", "host"]
        return endpoint.versionHeaders
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { AnalysisHTTPHeader($0.key, $0.value) }
            .filter { !reserved.contains($0.name) }
    }

    static func isValidModelID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    /// The host of an `https` URL with no user info, port, query or fragment.
    static func pinnedHost(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || isSafePath(components.path)
        else {
            return nil
        }
        return host
    }

    static func isSafePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 256 && !path.contains("..") && !path.contains("//")
            && !path.contains(where: { "?#\\@% ".contains($0) || $0.isNewline })
    }
}
