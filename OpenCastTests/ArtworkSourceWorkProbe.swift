import Foundation
@testable import OpenCast

// The lock protects counters read from the test actor and worker executor.
nonisolated final class ArtworkSourceWorkProbe: @unchecked Sendable {
    let previewGate = AsyncTestGate()
    private let lock = NSLock()
    private var hashes = 0
    private var previews = 0

    var hashCount: Int { lock.withLock { hashes } }
    var previewCount: Int { lock.withLock { previews } }

    @concurrent
    func hash(_ data: Data) async -> String {
        lock.withLock { hashes += 1 }
        return ArtworkPreviewGenerator.sourceHash(for: data)
    }

    @concurrent
    func preview(_ data: Data, _ sourceHash: String, _ key: String) async -> ArtworkPreview? {
        lock.withLock { previews += 1 }
        await previewGate.wait()
        return await ArtworkPreviewGenerator.generate(from: data, sourceHash: sourceHash, canonicalArtworkURLKey: key)
    }
}
