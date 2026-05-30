import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import OpenCastPlayback

@Suite
struct RemoteCommandPositionHandlerTests {
    private let handler = RemoteCommandPositionHandler()

    @Test
    func acceptsFinitePositionAndClampsToDuration() {
        var soughtPosition: TimeInterval?

        let status = handler.handle(
            positionTime: 500,
            state: RemoteCommandState(hasLoadedContent: true, isSeekable: true, duration: 180)
        ) { position in
            soughtPosition = position
        }

        #expect(status == .success)
        #expect(soughtPosition == 180)
    }

    @Test
    func rejectsChangePositionWhenNoEpisodeIsLoaded() {
        var soughtPosition: TimeInterval?

        let status = handler.handle(
            positionTime: 10,
            state: .empty
        ) { position in
            soughtPosition = position
        }

        #expect(status == .noSuchContent)
        #expect(soughtPosition == nil)
    }

    @Test
    func rejectsChangePositionWhenDurationIsNotSeekable() {
        var soughtPosition: TimeInterval?

        let status = handler.handle(
            positionTime: 10,
            state: RemoteCommandState(hasLoadedContent: true, isSeekable: false, duration: nil)
        ) { position in
            soughtPosition = position
        }

        #expect(status == .noSuchContent)
        #expect(soughtPosition == nil)
    }

    @Test
    func rejectsNonFinitePosition() {
        var soughtPosition: TimeInterval?

        let status = handler.handle(
            positionTime: .nan,
            state: RemoteCommandState(hasLoadedContent: true, isSeekable: true, duration: 180)
        ) { position in
            soughtPosition = position
        }

        #expect(status == .commandFailed)
        #expect(soughtPosition == nil)
    }
}
