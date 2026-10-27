import Foundation

nonisolated struct ModelStoreRelocationResult: Hashable, Sendable {
    nonisolated enum Outcome: Hashable, Sendable {
        /// The group store validated, its companions were copied, and the
        /// `.store` was renamed into the app container this launch.
        case moved
        /// No group `.store`; the app URL is the store (an earlier move, an
        /// install from before 2026-09-13, or a fresh install). Group
        /// leftovers, if any, were deleted or noted.
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
        /// The group `.store` could not be opened or probed (an open or probe
        /// failure other than ENOENT on the `.store`; a probe failure beside it).
        case inaccessible(String)
        /// A journal mode other than WAL, a `-journal` after the clean close,
        /// a checkpoint that did not complete (`busy != 0` or
        /// `log != checkpointed`), an unforeseen entry beside the group
        /// store, or a device-number mismatch between the two directories.
        case unsupported(String)
        /// A mutation in steps 3–5 failed (clear the destination, copy the
        /// companions, rename). The source is intact.
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
    /// Companion directory names found beside the group store.
    let companions: [String]
    /// Non-fatal observations: a leftover deletion that failed, a step 6
    /// cleanup failure, an app-side entry the package rule does not cover.
    let notes: [String]
}
