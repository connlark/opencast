import CryptoKit
import Foundation

/// Turns downloaded bytes into a bundle the app may use: size limits, the
/// signature envelope naming exactly these bytes (version and SHA-256), the
/// pinned-key signature over them (before any parsing), decoding, the named
/// version, the format version, the app build and the clamp, in that order.
public struct AnalysisPolicyValidator: Sendable {
    public static let maximumBundleBytes = 1_048_576
    public static let maximumSignatureBytes = 4_096

    public var verifier: AnalysisPolicySignatureVerifier
    public var appBuild: Int

    public init(verifier: AnalysisPolicySignatureVerifier = .pinned, appBuild: Int) {
        self.verifier = verifier
        self.appBuild = appBuild
    }

    public func validate(bundleData: Data, signatureData: Data) throws(AnalysisPolicyRejection) -> AnalysisPolicyBundle {
        guard bundleData.count <= Self.maximumBundleBytes else { throw .tooLarge(bytes: bundleData.count) }
        guard signatureData.count <= Self.maximumSignatureBytes else { throw .tooLarge(bytes: signatureData.count) }
        let binding = try AnalysisPolicySignatureVerifier.binding(in: signatureData)
        let digest = SHA256.hash(data: bundleData).map { String(format: "%02x", $0) }.joined()
        guard digest == binding.sha256 else {
            throw .signatureInvalid("bundle does not match the digest its signature names")
        }
        try verifier.verify(bundleData: bundleData, signatureData: signatureData)
        let bundle: AnalysisPolicyBundle
        do {
            bundle = try AnalysisPolicyBundle.decode(bundleData)
        } catch {
            throw .decodeFailed(Self.describe(error))
        }
        guard bundle.bundleVersion == binding.bundleVersion else {
            throw .signatureInvalid("bundle version does not match its signature")
        }
        guard bundle.schemaVersion == 1 else { throw .unsupportedSchemaVersion(bundle.schemaVersion) }
        guard bundle.minAppBuild <= appBuild else {
            throw .appBuildTooOld(required: bundle.minAppBuild, actual: appBuild)
        }
        try AnalysisPolicyClamp.validate(bundle)
        return bundle
    }

    /// The coding path of a decoding failure, never the document's content.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "not JSON" }
        let context: DecodingError.Context? = switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            context
        @unknown default:
            nil
        }
        let path = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
        return path.isEmpty ? "malformed document" : "malformed \(path)"
    }
}

extension AnalysisPolicyBundle {
    /// The bytes of the bundle this build ships with.
    public static var bakedData: Data { Data(BakedAnalysisPolicy.json.utf8) }

    /// The bundle this build ships with. The package's tests prove it decodes,
    /// passes the clamp and equals the served bundle of the same version.
    public static let baked: AnalysisPolicyBundle = {
        do {
            let bundle = try decode(bakedData)
            try AnalysisPolicyClamp.validate(bundle)
            return bundle
        } catch {
            fatalError("The baked analysis policy is invalid: \(error)")
        }
    }()
}
