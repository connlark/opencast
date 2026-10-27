import Foundation
import SwiftData

/// A row identified the way synced rows are, for the relocation round trip.
@Model
final class ModelStoreRoundTripRecord {
    var dedupeUUID: String = ""

    init(dedupeUUID: String) {
        self.dedupeUUID = dedupeUUID
    }
}
