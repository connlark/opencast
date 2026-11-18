import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("New-episode ad detection trigger")
struct NewEpisodeAdDetectionCoordinatorTests {
    @Test("A completion with a marker queues the episode once, as a prepared pass on this device, and takes the marker")
    func completionWithMarkerEnqueuesPrepared() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        let episode = fixture.addEpisode("new-1", state: .completed)
        fixture.mark("new-1")

        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)

        #expect(fixture.enqueued == [
            NewEpisodeAdDetectionCoordinator.EnqueueRequest(
                episode: episode,
                origin: .prepared,
                mode: .onDevice,
                presentsKeyScreen: false
            ),
        ])
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID.isEmpty)
        #expect(fixture.reloadedMarkers().isEmpty)
    }

    @Test("A completion without a marker queues nothing and leaves the other markers")
    func completionWithoutMarkerDoesNothing() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("hand-downloaded", state: .completed)
        fixture.addEpisode("pending", state: .downloading)
        fixture.mark("pending")

        fixture.coordinator.downloadCompleted(episodeID: "hand-downloaded", modelContext: fixture.context)

        #expect(fixture.enqueued.isEmpty)
        #expect(fixture.lookupCount == 0)
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID == ["pending": NewEpisodeTriggerFixture.show])
    }

    @Test("The same completion delivered twice queues once")
    func duplicateCompletionEnqueuesOnce() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("new-1", state: .completed)
        fixture.mark("new-1")

        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)
        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)
        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["new-1"])
    }

    @Test(
        "An episode that no longer qualifies is not queued, and its marker goes all the same",
        arguments: NewEpisodeAdDetectionDisqualifier.allCases
    )
    func disqualifiedEpisodeLosesMarker(_ disqualifier: NewEpisodeAdDetectionDisqualifier) throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("new-1", state: .completed)
        fixture.mark("new-1")
        fixture.apply(disqualifier, to: "new-1")

        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)

        #expect(fixture.enqueued.isEmpty)
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID.isEmpty)
        #expect(fixture.reloadedMarkers().isEmpty)
    }

    @Test("An episode with a finished or failed pass this session is queued again for its new download")
    func earlierOutcomeDoesNotBlock() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("new-1", state: .completed)
        fixture.mark("new-1")
        fixture.queueStatuses["new-1"] = .failed(message: "Transcript failed.")

        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["new-1"])
    }

    @Test("The sweep takes a completed download, drops a marker without a record, and keeps one still on its way")
    func sweepBranches() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("completed", state: .completed)
        fixture.addEpisode("no-record", state: nil)
        fixture.addEpisode("downloading", state: .downloading)
        fixture.addEpisode("paused", state: .paused)
        fixture.addEpisode("failed", state: .failed)
        fixture.addEpisode("file-gone", state: .completed, hasFile: false)
        fixture.mark("completed", "no-record", "downloading", "paused", "failed", "file-gone")

        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["completed"])
        let waiting = ["downloading", "paused", "failed", "file-gone"]
        #expect(Set(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID.keys) == Set(waiting))
        #expect(Set(fixture.reloadedMarkers().keys) == Set(waiting))

        fixture.records["paused"]?.state = .completed
        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["completed", "paused"])
    }

    @Test("Markers wait for the launch restore of the queue")
    func markersWaitForQueueRestore() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("new-1", state: .completed)
        fixture.mark("new-1")
        fixture.isQueueRestored = false

        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)
        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.enqueued.isEmpty)
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID == ["new-1": NewEpisodeTriggerFixture.show])

        fixture.isQueueRestored = true
        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["new-1"])
    }

    @Test("Turning the setting on takes the newest release already downloaded and marks none without a record")
    func enableMarksNewestRelease() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        let newest = NewEpisodeTriggerFixture.release(3)
        fixture.addEpisode("newest-downloaded", publishedAt: newest, state: .completed)
        fixture.addEpisode("newest-downloading", publishedAt: newest, state: .downloading)
        fixture.addEpisode("newest-not-downloaded", publishedAt: newest, state: nil)
        fixture.addEpisode("older-downloaded", publishedAt: NewEpisodeTriggerFixture.release(2), state: .completed)
        fixture.released[NewEpisodeTriggerFixture.show] = [
            "newest-downloaded", "newest-downloading", "newest-not-downloaded", "older-downloaded",
        ].compactMap { fixture.episodes[$0] }

        fixture.coordinator.enable(forPodcastID: NewEpisodeTriggerFixture.show, modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["newest-downloaded"])
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID == ["newest-downloading": NewEpisodeTriggerFixture.show])
        #expect(fixture.reloadedMarkers() == ["newest-downloading": NewEpisodeTriggerFixture.show])

        fixture.records["newest-downloading"]?.state = .completed
        fixture.coordinator.downloadCompleted(episodeID: "newest-downloading", modelContext: fixture.context)

        #expect(fixture.enqueued.map(\.episode.episodeID) == ["newest-downloaded", "newest-downloading"])
    }

    @Test("Marker rows the store never loaded survive turning the show off and its removal, and the sweep clears them once loaded")
    func unloadedMarkersAreLeftToTheSweep() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        let show = NewEpisodeTriggerFixture.show
        fixture.addEpisode("record-gone", state: nil)
        fixture.addEpisode("completed", state: .completed)
        // Unfinished: with the setting on its marker would wait; with the
        // setting off the sweep drops it rather than revisit it forever.
        fixture.addEpisode("paused", state: .paused)
        for episodeID in ["record-gone", "completed", "paused"] {
            fixture.context.insert(LocalPreferenceRecord(key: DownloadSettingsStore.detectAdsPendingKeyPrefix + episodeID, value: show))
        }
        try fixture.context.save()
        let unloaded = ["record-gone": show, "completed": show, "paused": show]
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID.isEmpty)

        // Each save would have deleted them had it fetched the show's markers.
        #expect(fixture.settings.setDetectsAdsInNewEpisodes(false, forPodcastID: show, modelContext: fixture.context))
        #expect(fixture.reloadedMarkers() == unloaded)
        #expect(fixture.settings.setAutoDownloadsNewEpisodes(false, forPodcastID: show, modelContext: fixture.context))
        #expect(fixture.reloadedMarkers() == unloaded)
        #expect(fixture.settings.removePreferences(forPodcastID: show, modelContext: fixture.context))
        #expect(fixture.reloadedMarkers() == unloaded)

        fixture.settings.load(modelContext: fixture.context)
        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.enqueued.isEmpty)
        #expect(fixture.settings.detectAdsPendingPodcastIDsByEpisodeID.isEmpty)
        #expect(fixture.reloadedMarkers().isEmpty)
    }

    @Test("With no markers, a completion and a sweep read nothing else")
    func noMarkersReadsNothing() throws {
        let fixture = try NewEpisodeTriggerFixture.make()
        fixture.addEpisode("new-1", state: .completed)

        fixture.coordinator.downloadCompleted(episodeID: "new-1", modelContext: fixture.context)
        fixture.coordinator.sweep(modelContext: fixture.context)

        #expect(fixture.lookupCount == 0)
        #expect(fixture.enqueued.isEmpty)
    }
}

enum NewEpisodeAdDetectionDisqualifier: CaseIterable, CustomTestStringConvertible {
    case played
    case archived
    case flagTurnedOff
    case unresolved
    case alreadyQueued
    case running

    var testDescription: String {
        switch self {
        case .played: "played"
        case .archived: "archived"
        case .flagTurnedOff: "flag turned off"
        case .unresolved: "episode gone from the library"
        case .alreadyQueued: "already queued"
        case .running: "already running"
        }
    }
}

@MainActor
private final class NewEpisodeTriggerFixture {
    static let show = "https://example.com/prepared.xml"
    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    static func release(_ day: Int) -> Date {
        base.addingTimeInterval(Double(day) * 86_400)
    }

    let container: ModelContainer
    let context: ModelContext
    let settings = DownloadSettingsStore()
    var records: [String: EpisodeDownloadRecord] = [:]
    var episodes: [String: EpisodeListItemSnapshot] = [:]
    var released: [String: [EpisodeListItemSnapshot]] = [:]
    var queueStatuses: [String: AdFreePassQueueEpisodeStatus] = [:]
    var isQueueRestored = true
    private var episodeIDsWithFiles: Set<String> = []
    private var playedEpisodeIDs: Set<String> = []
    private var archivedEpisodeIDs: Set<String> = []
    private(set) var lookupCount = 0
    private(set) var enqueued: [NewEpisodeAdDetectionCoordinator.EnqueueRequest] = []
    private(set) var coordinator: NewEpisodeAdDetectionCoordinator!

    private init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    static func make() throws -> NewEpisodeTriggerFixture {
        let fixture = NewEpisodeTriggerFixture(container: try OpenCastModelContainerFactory.make(inMemory: true))
        fixture.settings.load(modelContext: fixture.context)
        #expect(fixture.settings.setAutoDownloadsNewEpisodes(
            true,
            forPodcastID: show,
            watermark: .distantPast,
            modelContext: fixture.context
        ))
        #expect(fixture.settings.setDetectsAdsInNewEpisodes(true, forPodcastID: show, modelContext: fixture.context))
        fixture.coordinator = NewEpisodeAdDetectionCoordinator(
            settings: fixture.settings,
            downloadRecord: { [unowned fixture] episodeID in
                fixture.lookupCount += 1
                return fixture.records[episodeID]
            },
            hasDownloadedFile: { [unowned fixture] record in
                fixture.lookupCount += 1
                return fixture.episodeIDsWithFiles.contains(record.episodeID)
            },
            episode: { [unowned fixture] episodeID in
                fixture.lookupCount += 1
                return fixture.episodes[episodeID]
            },
            releasedEpisodes: { [unowned fixture] podcastID in
                fixture.lookupCount += 1
                return fixture.released[podcastID] ?? []
            },
            isPlayedOrArchived: { [unowned fixture] episodeID in
                fixture.lookupCount += 1
                return fixture.playedEpisodeIDs.contains(episodeID) || fixture.archivedEpisodeIDs.contains(episodeID)
            },
            queueStatus: { [unowned fixture] episodeID in
                fixture.lookupCount += 1
                return fixture.queueStatuses[episodeID] ?? .notQueued
            },
            isQueueRestored: { [unowned fixture] in
                fixture.lookupCount += 1
                return fixture.isQueueRestored
            },
            enqueue: { [unowned fixture] request, _ in
                fixture.enqueued.append(request)
            }
        )
        return fixture
    }

    /// A nil `state` leaves the episode without a download record.
    @discardableResult
    func addEpisode(
        _ episodeID: String,
        publishedAt: Date = NewEpisodeTriggerFixture.release(1),
        state: EpisodeDownloadState?,
        hasFile: Bool = true
    ) -> EpisodeListItemSnapshot {
        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: episodeID,
            podcastID: Self.show,
            publishedAt: publishedAt,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
        episodes[episodeID] = episode
        if let state {
            records[episodeID] = EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: Self.show,
                sourceAudioURL: "https://example.com/\(episodeID).mp3",
                state: state
            )
        }
        if hasFile {
            episodeIDsWithFiles.insert(episodeID)
        }
        return episode
    }

    func mark(_ episodeIDs: String...) {
        let markers = Dictionary(uniqueKeysWithValues: episodeIDs.map { ($0, Self.show) })
        #expect(settings.addDetectAdsPendingMarkers(markers, modelContext: context))
    }

    func apply(_ disqualifier: NewEpisodeAdDetectionDisqualifier, to episodeID: String) {
        switch disqualifier {
        case .played:
            playedEpisodeIDs.insert(episodeID)
        case .archived:
            archivedEpisodeIDs.insert(episodeID)
        case .flagTurnedOff:
            // Straight to the row: the store's own setter would take the
            // marker away with the flag.
            try? LocalPreferenceRecord.deletePreferences(
                forKey: DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix + Self.show,
                modelContext: context
            )
            try? context.save()
            settings.load(modelContext: context)
        case .unresolved:
            episodes[episodeID] = nil
        case .alreadyQueued:
            queueStatuses[episodeID] = .queued(ahead: 1)
        case .running:
            queueStatuses[episodeID] = .running
        }
    }

    func reloadedMarkers() -> [String: String] {
        let store = DownloadSettingsStore()
        store.load(modelContext: ModelContext(container))
        return store.detectAdsPendingPodcastIDsByEpisodeID
    }
}
