import Foundation
import SwiftData

/// A payload large enough that Core Data keeps it in the store's
/// `_EXTERNAL_DATA` companion rather than in the SQLite file.
@Model
final class ModelStoreRoundTripPayloadRecord {
    var dedupeUUID: String = ""
    @Attribute(.externalStorage) var payload: Data = Data()

    init(dedupeUUID: String, payload: Data) {
        self.dedupeUUID = dedupeUUID
        self.payload = payload
    }
}
