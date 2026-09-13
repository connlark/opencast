import Foundation
import Testing
@testable import OpenCast

@MainActor
struct RemoteEpisodeNotificationRouteBridgeTests {
    @Test("A live route stream does not retain its bridge through termination")
    func streamReleasesBridge() {
        var bridge: RemoteEpisodeNotificationRouteBridge? = RemoteEpisodeNotificationRouteBridge()
        weak let releasedBridge = bridge
        let stream = bridge?.routes()
        bridge = nil
        withExtendedLifetime(stream) {
            #expect(releasedBridge == nil)
        }
    }
}
