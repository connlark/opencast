import SwiftUI
import Testing
@testable import OpenCast

@Suite("Playlists tab availability")
struct PlaylistsTabAvailabilityTests {
    private static func decisions(for sizeClasses: [UserInterfaceSizeClass?]) -> [Bool] {
        sizeClasses.map { OpenCastTabRootView.offersPlaylistsTab(horizontalSizeClass: $0) }
    }

    @Test("Compact width withholds the tab; a window that turns regular offers it again")
    func compactWidthWithholdsIt() {
        #expect(Self.decisions(for: [.compact]) == [false])
        #expect(Self.decisions(for: [.regular, .compact, .regular]) == [true, false, true])
    }
}
