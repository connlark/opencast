import Foundation

public struct OpenCastRemoteModelGatewayConfiguration: Sendable, Equatable {
    public var baseURL: URL
    public var manifestPath: String
    public var manifestSignaturePath: String

    public init(
        baseURL: URL = Self.defaultBaseURL,
        manifestPath: String = "/v1/models/manifest",
        manifestSignaturePath: String = "/v1/models/manifest.sig"
    ) {
        self.baseURL = baseURL
        self.manifestPath = manifestPath
        self.manifestSignaturePath = manifestSignaturePath
    }

    public static let defaultBaseURL = URL(string: "https://models.example.com")!

    public func manifestURL() throws -> URL {
        try url(forPath: manifestPath, pathKind: "manifest")
    }

    public func manifestSignatureURL() throws -> URL {
        try url(forPath: manifestSignaturePath, pathKind: "manifest signature")
    }

    public func assetURL(forPath path: String) throws -> URL {
        try url(forPath: path, pathKind: "asset")
    }

    private func url(forPath path: String, pathKind: String) throws -> URL {
        try validateUnescapedAbsolutePath(path, pathKind: pathKind)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "bad remote model gateway base URL: \(baseURL.absoluteString)"
            )
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "could not construct \(pathKind) URL for path \(path)"
            )
        }
        return url
    }

    private func validateUnescapedAbsolutePath(_ path: String, pathKind: String) throws {
        guard path.hasPrefix("/") else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "\(pathKind) URL paths must be absolute paths"
            )
        }
        guard !path.contains("%"),
              !path.contains("\\"),
              !path.contains("?"),
              !path.contains("#") else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "\(pathKind) URL paths must be unescaped absolute paths"
            )
        }
    }
}
