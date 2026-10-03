import CoreTransferable
import Foundation

/// The "Share from Current Time" item: the share sheet asks for the link as
/// it opens and again when a destination is chosen, so the start is wherever
/// playback is when the link is sent, and the menu offering it never has to
/// change while the episode plays. Some of those asks come off the main
/// thread, so `url` must not need the main actor.
nonisolated struct EpisodeCurrentTimeShareLink: Transferable {
    let url: @Sendable () -> URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { link in
            link.url()
        }
    }
}
