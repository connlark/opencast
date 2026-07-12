import Foundation
@testable import OpenCastTranscription

struct AcceptingManifestVerifier: OpenCastRemoteModelManifestVerifying {
    func verify(manifestData: Data, signatureData: Data) throws {}
}
