import Foundation
@testable import OpenCastTranscription

struct RejectingManifestVerifier: OpenCastRemoteModelManifestVerifying {
    func verify(manifestData: Data, signatureData: Data) throws {
        throw OpenCastTranscriptionError.invalidRemoteManifestSignature("fixture rejection")
    }
}
