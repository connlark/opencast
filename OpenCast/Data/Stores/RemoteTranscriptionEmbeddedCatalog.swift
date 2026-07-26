import Foundation
import OpenCastTranscription

/// The app's embedded copy of the transcription credit catalog. Mirrors
/// `fastlane/in_app_purchases/remote_transcription.json` and PurchaseWorker's
/// embedded catalog; the SHA-256 is over the canonical
/// `[{grant_seconds, product_id}]` mapping sorted by product ID. Any
/// mismatch with the server's bootstrap catalog fails closed: the store is
/// hidden rather than selling drifted grants.
nonisolated enum RemoteTranscriptionEmbeddedCatalog {
    static let catalogSHA256 = "c2b007bc37825865aa679166a6fa7d1b0d74c141999f459c12e056f3c7134ec5"

    /// Server overdraft cap (parent plan): reservations may ride up to this
    /// much debt; the consumption preview mirrors the same arithmetic.
    static let debtCapSeconds: Int64 = 10_800

    static let products: [OpenCastRemoteTranscriptionCatalogProduct] = [
        OpenCastRemoteTranscriptionCatalogProduct(
            productID: "com.connor.opencast.transcription.hours20.v1",
            grantSeconds: 72_000
        ),
        OpenCastRemoteTranscriptionCatalogProduct(
            productID: "com.connor.opencast.transcription.hours100.v1",
            grantSeconds: 360_000
        ),
    ]

    static var productIDs: [String] {
        products.map(\.productID)
    }

    static var grantSecondsByProductID: [String: Int64] {
        Dictionary(uniqueKeysWithValues: products.map { ($0.productID, $0.grantSeconds) })
    }

    /// Fail-closed cross-check of the server's bootstrap catalog.
    static func matches(
        serverCatalog: [OpenCastRemoteTranscriptionCatalogProduct]?,
        serverHash: String?
    ) -> Bool {
        guard let serverCatalog, let serverHash else { return false }
        let sortedServer = serverCatalog.sorted { $0.productID < $1.productID }
        let sortedEmbedded = products.sorted { $0.productID < $1.productID }
        return serverHash == catalogSHA256 && sortedServer == sortedEmbedded
    }
}
