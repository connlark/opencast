import CoreTransferable
import Foundation

/// The share sheet asks for the link as it opens and again when a destination is chosen, some
/// asks off the main thread, so `url` must not need the main actor.
nonisolated struct EpisodeCurrentTimeShareLink: Transferable {
    let url: @Sendable () -> URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { link in
            link.url()
        }
    }
}
