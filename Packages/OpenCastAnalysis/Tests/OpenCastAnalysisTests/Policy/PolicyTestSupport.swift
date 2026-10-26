import Foundation
@testable import OpenCastAnalysis

enum PolicyTestSupport {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static let gatewayDirectory = repoRoot.appending(path: "Server/ModelGatewayWorker")

    static func gatewayFile(_ relativePath: String) throws -> Data {
        try Data(contentsOf: gatewayDirectory.appending(path: relativePath))
    }

    static let testVerifier = AnalysisPolicySignatureVerifier(
        publicKeyHex: AnalysisPolicyTestFixtures.publicKeyHex,
        keyID: AnalysisPolicyTestFixtures.keyID
    )

    static let appBuild = 301

    static func data(_ fixture: AnalysisPolicyFixture) -> (bundle: Data, signature: Data) {
        (Data(fixture.bundle.utf8), Data(fixture.signature.utf8))
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "AnalysisPolicyTests-\(UUID().uuidString)")
    }
}
