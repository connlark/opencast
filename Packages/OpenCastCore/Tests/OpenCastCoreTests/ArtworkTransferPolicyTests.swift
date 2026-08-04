import Foundation
import Testing
@testable import OpenCastCore

@Suite("Artwork transfer policy")
struct ArtworkTransferPolicyTests {
    @Test("Byte admission bounds the transfer without policing MIME")
    func byteAdmissionBoundsTransfer() {
        #expect(ArtworkTransferPolicy.admitsByteCount(1_024))
        #expect(ArtworkTransferPolicy.admitsByteCount(ArtworkTransferPolicy.maximumByteCount))

        #expect(!ArtworkTransferPolicy.admitsByteCount(0))
        #expect(!ArtworkTransferPolicy.admitsByteCount(-1))
        #expect(!ArtworkTransferPolicy.admitsByteCount(ArtworkTransferPolicy.maximumByteCount + 1))
    }

    @Test("Pixel-dimension admission refuses extreme declared canvases")
    func pixelDimensionAdmissionRefusesExtremes() {
        #expect(ArtworkTransferPolicy.admitsPixelDimensions(width: 3_000, height: 3_000))
        #expect(ArtworkTransferPolicy.admitsPixelDimensions(width: nil, height: nil))
        #expect(ArtworkTransferPolicy.admitsPixelDimensions(
            width: ArtworkTransferPolicy.maximumPixelDimension,
            height: ArtworkTransferPolicy.maximumPixelDimension
        ))

        #expect(!ArtworkTransferPolicy.admitsPixelDimensions(
            width: ArtworkTransferPolicy.maximumPixelDimension + 1,
            height: 100
        ))
        #expect(!ArtworkTransferPolicy.admitsPixelDimensions(
            width: 100,
            height: ArtworkTransferPolicy.maximumPixelDimension + 1
        ))
    }
}
