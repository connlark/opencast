import Testing
@testable import OpenCast

@MainActor
@Suite("Tab refreshes")
struct TabRefreshesTests {
    private typealias Refreshes = OpenCastTabRootView.TabRefreshes
    private static let launchSet: Set<AppSection> = [.library, .inbox, .downloads, .settings, .search]

    @Test("The initial membership takes a generation each, every one distinct")
    func initialMembership() {
        var refreshes = Refreshes()
        let change = refreshes.observe(Self.launchSet)
        #expect(Set(change.added.map(\.section)) == Self.launchSet)
        #expect(Set(change.added.map(\.generation)).count == Self.launchSet.count)
        #expect(change.withdrawn.isEmpty)
    }

    @Test("A late Playlists and a late Up Next each take their own")
    func lateInstallations() throws {
        var refreshes = Refreshes()
        _ = refreshes.observe(Self.launchSet)
        let library = refreshes.generation(of: .library)

        let playlists = try #require(refreshes.observe(Self.launchSet.union([.playlists])).added.first)
        let upNext = try #require(refreshes.observe(Self.launchSet.union([.playlists, .upNext])).added.first)
        #expect(playlists.section == .playlists)
        #expect(upNext.section == .upNext)
        #expect(playlists.generation != upNext.generation)
        #expect(refreshes.generation(of: .library) == library)
    }

    @Test("Withdrawal before the refresh clears the generation, reported once")
    func withdrawalBeforeTheRefresh() throws {
        var refreshes = Refreshes()
        let upNext = try #require(refreshes.observe([.upNext]).added.first)
        #expect(refreshes.observe([]).withdrawn == [upNext])
        #expect(refreshes.generation(of: .upNext) == nil)
        #expect(refreshes.observe([]).withdrawn.isEmpty)
    }

    @Test("A reinstallation takes a fresh token, never an earlier one")
    func reinstallation() throws {
        var refreshes = Refreshes()
        let first = try #require(refreshes.observe([.upNext]).added.first)
        _ = refreshes.observe([])

        let second = try #require(refreshes.observe([.upNext]).added.first)

        #expect(second.generation != first.generation)
    }
}
