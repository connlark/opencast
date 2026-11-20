import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Sound Lab artwork below the floor")
struct NowPlayingSoundLabArtworkFloorTests {
    @Test(
        "The inline panel renders from the floor up and never below it",
        arguments: [(side: 120.0, renders: false), (side: 153.5, renders: false), (side: 156.33, renders: true)]
    )
    func inlinePanelOnlyFromTheFloor(side: Double, renders: Bool) throws {
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            allowsAutomaticFeedRefresh: false
        )
        var requests = 0
        let artwork = NowPlayingSoundLabArtwork(
            title: "Show",
            imageURL: nil,
            size: side,
            voiceBoostEnabled: .constant(true),
            voiceBoostControlEnabled: true,
            onAdFreePassAction: {},
            onTranscribeRemotely: {},
            onTranscriptAction: {},
            onAdFreePassBackgroundProbe: {},
            onRequestSoundLabSheet: { requests += 1 },
            isSoundLabInteractionActive: .constant(false),
            isCardDismissDragActive: false
        )
        .environment(appModel)
        .environment(\.appStoreSoundLabRevealProgress, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        let rendered = try NowPlayingSoundLabHostedFitTests.render(artwork, square: side)
        #expect(rendered.switches.isEmpty == !renders, "switches \(rendered.switches)")
        #expect(rendered.rows.isEmpty == !renders, "rows \(rendered.rows)")
        #expect(requests == 0)
    }
}
