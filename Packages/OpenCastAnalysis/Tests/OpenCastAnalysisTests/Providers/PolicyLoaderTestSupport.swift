import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// A clock the tests move by hand.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) {
        current = Mutex(start)
    }

    func now() -> Date {
        current.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 += interval }
    }
}

/// A gateway the tests script: one mutable current signature and the
/// immutable versioned bundles published so far. Counts every fetch.
actor ScriptedPolicyFetcher: AnalysisPolicyFetching {
    enum Response {
        /// Publish `bundle` under the version its signature names and make
        /// `signature` current.
        case documents(bundle: Data, signature: Data)
        case offline
    }

    private var signature: Data?
    private var bundles: [Int: Data] = [:]
    private var offline = false
    private(set) var fetchCount = 0
    private(set) var fetchedPaths: [String] = []

    init(_ response: Response) {
        if case let .documents(bundle, signature) = response {
            self.signature = signature
            if let version = Self.version(named: signature) {
                bundles[version] = bundle
            }
        } else {
            offline = true
        }
    }

    init(_ fixture: AnalysisPolicyFixture) {
        let documents = PolicyTestSupport.data(fixture)
        self.init(.documents(bundle: documents.bundle, signature: documents.signature))
    }

    private static func version(named signature: Data) -> Int? {
        try? AnalysisPolicySignatureVerifier.binding(in: signature).bundleVersion
    }

    func serve(_ response: Response) {
        apply(response)
    }

    func serve(_ fixture: AnalysisPolicyFixture) {
        let documents = PolicyTestSupport.data(fixture)
        apply(.documents(bundle: documents.bundle, signature: documents.signature))
    }

    /// Publishes a fixture's bundle at its version without touching the
    /// current signature.
    func publishBundle(of fixture: AnalysisPolicyFixture) throws {
        let documents = PolicyTestSupport.data(fixture)
        let version = try AnalysisPolicySignatureVerifier.binding(in: documents.signature).bundleVersion
        bundles[version] = documents.bundle
    }

    /// Serves arbitrary bytes at a versioned URL, as a broken publish would.
    func replaceBundle(at version: Int, with data: Data) {
        bundles[version] = data
    }

    func replaceSignature(with data: Data) {
        signature = data
        offline = false
    }

    private func apply(_ response: Response) {
        switch response {
        case .offline:
            offline = true
        case let .documents(bundle, signature):
            offline = false
            self.signature = signature
            if let version = Self.version(named: signature) {
                bundles[version] = bundle
            }
        }
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        fetchCount += 1
        fetchedPaths.append(url.path())
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let data: Data?
        if url.lastPathComponent == "analysis.sig" {
            data = signature
        } else if url.lastPathComponent.hasSuffix(".json"),
                  let version = Int(url.lastPathComponent.dropLast(".json".count)) {
            data = bundles[version]
        } else {
            data = nil
        }
        guard let data else { throw AnalysisPolicyRejection.fetchFailed("http_404") }
        guard data.count <= maximumBytes else { throw AnalysisPolicyRejection.tooLarge(bytes: data.count) }
        return data
    }
}
