import DeviceCheck
import Foundation
import OpenCastTranscription

/// The privacy-safe reduction of a thrown error for remote-job diagnostics:
/// a vocabulary domain, the framework's numeric code, a closed framework
/// domain and a closed machine code. No field accepts free text, so a URL
/// or title embedded in an error message cannot reach disk.
nonisolated struct RemoteJobDiagnosticError: Codable, Sendable, Equatable {
    enum Domain: String, Codable, Sendable, CaseIterable {
        case transport
        case http
        case appAttest
        case keychain
        case deviceCheck
        case decode
        case download
        case validation
        case cancellation
        case runner
        case other
    }

    /// Closed set of `NSError.domain` values worth keeping for triage;
    /// anything else collapses to `other`.
    enum FrameworkDomain: String, Codable, Sendable, CaseIterable {
        case urlError
        case cocoa
        case posix
        case osStatus
        case mach
        case deviceCheck
        case coreML
        case other

        init(nsDomain: String) {
            self = switch nsDomain {
            case URLError.errorDomain: .urlError
            case NSCocoaErrorDomain: .cocoa
            case NSPOSIXErrorDomain: .posix
            case NSOSStatusErrorDomain: .osStatus
            case NSMachErrorDomain: .mach
            case DCError.errorDomain: .deviceCheck
            case "com.apple.CoreML": .coreML
            default: .other
            }
        }
    }

    /// Closed set of client-side machine codes.
    enum LocalCode: String, Codable, Sendable, CaseIterable {
        // Client-side HTTP layer.
        case invalidResponse
        case responseTooLarge
        case missingLocalFile
        // Decoding.
        case typeMismatch
        case valueNotFound
        case keyNotFound
        case dataCorrupted
        // Downloads.
        case fileMissing
        case notCompleted
        // Result validation.
        case sourceIdentityMismatch
        case invalidDuration
        case emptyTranscript
        case invalidTimings
        case textMismatch
        case normalizedHashMismatch
        case unsupportedSchema
        // Runner outcomes.
        case downloadFailed
        case remoteCancelled
        case mismatchLocalFallback
        case resultInvalid
        case serviceUnavailable
        case connectionLost
        case localRequestFailed
        case acknowledgedWithoutLocalImport
    }

    let domain: Domain
    /// URLError code, HTTP status, OSStatus, DCError code or NSError code.
    let code: Int?
    let frameworkDomain: FrameworkDomain?
    /// The server's stable wire error code; values this client does not
    /// know encode as `unknown`.
    let wireCode: OpenCastRemoteTranscriptionErrorCode?
    let localCode: LocalCode?

    static let allowedFieldNames: Set<String> = ["domain", "code", "frameworkDomain", "wireCode", "localCode"]

    init(
        domain: Domain,
        code: Int? = nil,
        frameworkDomain: FrameworkDomain? = nil,
        wireCode: OpenCastRemoteTranscriptionErrorCode? = nil,
        localCode: LocalCode? = nil
    ) {
        self.domain = domain
        self.code = code
        self.frameworkDomain = frameworkDomain
        self.wireCode = wireCode
        self.localCode = localCode
    }

    init(classifying error: any Error) {
        switch error {
        case is CancellationError:
            self.init(domain: .cancellation)
        case let urlError as URLError:
            self.init(domain: .transport, code: urlError.errorCode, frameworkDomain: .urlError)
        case let httpError as RemoteTranscriptionHTTPError:
            // A non-positive status is client-side: no HTTP exchange landed.
            self.init(
                domain: httpError.statusCode > 0 ? .http : .transport,
                code: httpError.statusCode,
                wireCode: Self.knownWireCode(httpError.code),
                localCode: Self.localCode(forClientCode: httpError.code)
            )
        case let appAttestError as AppAttestHTTPError:
            self.init(domain: .appAttest, code: appAttestError.statusCode, wireCode: Self.knownWireCode(appAttestError.code))
        case let keychainError as AppAttestKeychainError:
            self.init(domain: .keychain, code: Int(keychainError.status))
        case let runError as RemoteTranscriptionJobRunError:
            self.init(domain: .runner, wireCode: Self.wireCode(for: runError), localCode: Self.localCode(for: runError))
        case let decodingError as DecodingError:
            self.init(domain: .decode, localCode: Self.localCode(for: decodingError))
        case let downloadError as DownloadStore.CompletedDownloadError:
            self.init(domain: .download, localCode: Self.localCode(for: downloadError))
        case let validationError as EpisodeRemoteTranscriptMapper.ValidationError:
            self.init(domain: .validation, localCode: Self.localCode(for: validationError))
        default:
            let nsError = error as NSError
            let frameworkDomain = FrameworkDomain(nsDomain: nsError.domain)
            self.init(
                domain: frameworkDomain == .deviceCheck ? .deviceCheck : .other,
                code: nsError.code,
                frameworkDomain: frameworkDomain
            )
        }
    }

    /// The encoded form of a wire code: known values verbatim, anything
    /// else collapsed to `unknown`.
    static func encodedWireCode(_ code: OpenCastRemoteTranscriptionErrorCode) -> String {
        if case .unknown = code {
            return "unknown"
        }
        return code.wireValue
    }

    private static func knownWireCode(_ value: String) -> OpenCastRemoteTranscriptionErrorCode? {
        let code = OpenCastRemoteTranscriptionErrorCode(wireValue: value)
        if case .unknown = code {
            return nil
        }
        return code
    }

    private static func localCode(forClientCode code: String) -> LocalCode? {
        switch code {
        case "invalid_response": .invalidResponse
        case "response_too_large": .responseTooLarge
        case "download_failed": .downloadFailed
        case "missing_local_file": .missingLocalFile
        default: nil
        }
    }

    private static func wireCode(for error: RemoteTranscriptionJobRunError) -> OpenCastRemoteTranscriptionErrorCode? {
        if case .serverRejected(let code) = error {
            return knownWireCode(code.wireValue)
        }
        return nil
    }

    private static func localCode(for error: RemoteTranscriptionJobRunError) -> LocalCode? {
        switch error {
        case .downloadFailed: .downloadFailed
        case .serverRejected: nil
        case .remoteCancelled: .remoteCancelled
        case .mismatchLocalFallback: .mismatchLocalFallback
        case .resultInvalid: .resultInvalid
        case .serviceUnavailable: .serviceUnavailable
        case .connectionLost: .connectionLost
        case .localRequestFailed: .localRequestFailed
        case .acknowledgedWithoutLocalImport: .acknowledgedWithoutLocalImport
        }
    }

    private static func localCode(for error: DecodingError) -> LocalCode? {
        switch error {
        case .typeMismatch: .typeMismatch
        case .valueNotFound: .valueNotFound
        case .keyNotFound: .keyNotFound
        case .dataCorrupted: .dataCorrupted
        @unknown default: nil
        }
    }

    private static func localCode(for error: DownloadStore.CompletedDownloadError) -> LocalCode {
        switch error {
        case .fileMissing: .fileMissing
        case .notCompleted: .notCompleted
        }
    }

    private static func localCode(for error: EpisodeRemoteTranscriptMapper.ValidationError) -> LocalCode {
        switch error {
        case .sourceIdentityMismatch: .sourceIdentityMismatch
        case .invalidDuration: .invalidDuration
        case .emptyTranscript: .emptyTranscript
        case .invalidTimings: .invalidTimings
        case .textMismatch: .textMismatch
        case .normalizedHashMismatch: .normalizedHashMismatch
        case .unsupportedSchema: .unsupportedSchema
        }
    }

    private enum CodingKeys: String, CodingKey {
        case domain, code, frameworkDomain, wireCode, localCode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            domain: try container.decode(Domain.self, forKey: .domain),
            code: try container.decodeIfPresent(Int.self, forKey: .code),
            frameworkDomain: try container.decodeIfPresent(FrameworkDomain.self, forKey: .frameworkDomain),
            wireCode: try container.decodeIfPresent(String.self, forKey: .wireCode)
                .map(OpenCastRemoteTranscriptionErrorCode.init(wireValue:)),
            localCode: try container.decodeIfPresent(LocalCode.self, forKey: .localCode)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(frameworkDomain, forKey: .frameworkDomain)
        try container.encodeIfPresent(wireCode.map(Self.encodedWireCode), forKey: .wireCode)
        try container.encodeIfPresent(localCode, forKey: .localCode)
    }
}
