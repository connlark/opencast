import Testing
@testable import OpenCast

@MainActor
struct OpenCastPlaylistShortcutParametersTests {
    @Test func sameNameCreationDeletionAndReplacementChangeTheRefreshKey() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        await fixture.model.ensurePlaybackSurfaceHydrated(modelContext: fixture.context)
        let store = fixture.model.playlists
        let first = try #require(store.create(name: "Commute", kind: .manual, modelContext: fixture.context))
        let original = OpenCastPlaylistShortcutParameters(playlists: store.playlists)

        _ = try #require(store.create(name: "Commute", kind: .manual, modelContext: fixture.context))
        let duplicated = OpenCastPlaylistShortcutParameters(playlists: store.playlists)
        #expect(duplicated != original)

        #expect(store.delete(first.playlistID, modelContext: fixture.context))
        let replacement = OpenCastPlaylistShortcutParameters(playlists: store.playlists)
        #expect(replacement != duplicated)
        #expect(replacement != original)
        #expect(Array(replacement.namesByID.values) == ["Commute"])
    }

    @Test func renameChangesTheKeyButCollectionOrderAndCountsDoNot() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        await fixture.model.ensurePlaybackSurfaceHydrated(modelContext: fixture.context)
        let store = fixture.model.playlists
        let playlist = try #require(store.create(name: "Commute", kind: .manual, modelContext: fixture.context))
        _ = try #require(store.create(name: "Weekend", kind: .manual, modelContext: fixture.context))
        let original = OpenCastPlaylistShortcutParameters(playlists: store.playlists)

        let episode = try #require(fixture.model.episodeSnapshot(for: "episode-1"))
        #expect(store.add([episode], to: playlist.playlistID, modelContext: fixture.context) == 1)
        #expect(OpenCastPlaylistShortcutParameters(playlists: Array(store.playlists.reversed())) == original)

        #expect(store.rename(playlist.playlistID, to: "Morning", modelContext: fixture.context))
        #expect(OpenCastPlaylistShortcutParameters(playlists: store.playlists) != original)
    }
}
