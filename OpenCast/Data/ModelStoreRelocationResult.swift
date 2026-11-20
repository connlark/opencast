import Foundation

nonisolated struct ModelStoreRelocationResult: Hashable, Sendable {
    nonisolated enum Outcome: Hashable, Sendable {
        case moved
        /// No group `.store`, so the app URL is the store. Group leftovers were deleted or noted.
        case inPlace
        /// No `.store` at either URL but leftovers beside the group URL;
        /// nothing deleted, the app URL resolved.
        case ambiguous
        /// The group store stays authoritative this launch; nothing deleted.
        case deferred(Deferral)
    }

    nonisolated enum Deferral: Hashable, Sendable {
        /// The group store opens but has no usable schema (no table, or no
        /// `Z_METADATA`).
        case invalid(String)
        /// An open or probe failure other than ENOENT on the group `.store`, or a probe failure
        /// beside it.
        case inaccessible(String)
        /// Not WAL mode, a `-journal` after the clean close, an incomplete checkpoint (`busy != 0`
        /// or `log != checkpointed`), an unforeseen entry, or the directories on different devices.
        case unsupported(String)
        /// A mutation in steps 3 to 5 failed; the source is intact.
        case interrupted(Step, String)
    }

    nonisolated enum Step: String, Hashable, Sendable {
        case clearDestination, copyCompanions, commit
    }

    let configurationName: String
    let resolvedURL: URL
    let outcome: Outcome
    /// `Z_METADATA.Z_UUID` of the group store, when it was read.
    let storeUUID: String?
    /// Size in bytes of the group `-wal` before the checkpoint, when it was probed.
    let walSize: Int?
    let companions: [String]
    let notes: [String]
}
