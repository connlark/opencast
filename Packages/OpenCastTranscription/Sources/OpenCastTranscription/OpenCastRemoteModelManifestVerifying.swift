import Foundation

protocol OpenCastRemoteModelManifestVerifying: Sendable {
    func verify(manifestData: Data, signatureData: Data) throws
}
