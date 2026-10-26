import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Testing
@testable import OpenCast

/// Generate's route check before the disclosure: the key screen opens only
/// when no run could start, and from what is already known (no request).
@MainActor
@Suite("Chapters & Summary start gate")
struct ChaptersSummaryStartGateTests {
    @Test("No key and the trial used up opens the key screen for Chapters & Summary")
    func noKeyTrialExhaustedOpensKeyScreen() async throws {
        let appModel = try await makeAppModel(trial: .exhausted)

        #expect(appModel.presentChaptersSummaryKeyScreenIfNoRoute())
        let request = try #require(appModel.analysisKeyRequired.request)
        #expect(request.feature == .chaptersSummary)
        #expect(request.trialStatus == .exhausted)
    }

    @Test("A trial status the cache already read decides too")
    func cachedTrialStatusDecides() async throws {
        let appModel = try await makeAppModel(trial: .exhausted, keyNoticeStatus: .some(nil))
        _ = await appModel.analysisTrialStatus.status(forceRefresh: true)

        #expect(appModel.presentChaptersSummaryKeyScreenIfNoRoute())
        #expect(appModel.analysisKeyRequired.request?.feature == .chaptersSummary)
    }

    @Test("A paused month opens the key screen only while the status is fresh")
    func pausedMonthWhileFresh() async throws {
        let appModel = try await makeAppModel(trial: .unitsLeft(2), paused: true)
        #expect(!appModel.presentChaptersSummaryKeyScreenIfNoRoute())
        _ = await appModel.analysisTrialStatus.status(forceRefresh: true)
        #expect(appModel.presentChaptersSummaryKeyScreenIfNoRoute())
        #expect(appModel.analysisKeyRequired.request?.feature == .chaptersSummary)
    }

    @Test("Free analyses left, or the trial not started, leave Generate to the disclosure")
    func trialWithRoomPasses() async throws {
        for trial in [AnalysisTrialStatus.unitsLeft(3), .notStarted] {
            let appModel = try await makeAppModel(trial: trial)
            #expect(!appModel.presentChaptersSummaryKeyScreenIfNoRoute())
            #expect(appModel.analysisKeyRequired.request == nil)
        }
    }

    @Test("A saved key leaves Generate to the disclosure whatever the trial says")
    func savedKeyPasses() async throws {
        let appModel = try await makeAppModel(trial: .exhausted, seedsGoogleKey: true)

        #expect(!appModel.presentChaptersSummaryKeyScreenIfNoRoute())
        #expect(appModel.analysisKeyRequired.request == nil)
    }

    private func makeAppModel(
        trial: AnalysisTrialStatus,
        keyNoticeStatus: AnalysisTrialStatus?? = .none,
        paused: Bool = false,
        seedsGoogleKey: Bool = false
    ) async throws -> OpenCastAppModel {
        let fixtureStatus: AnalysisTrialProxyStatus = switch trial {
        case .unitsLeft(let units):
            AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: units, startsAt: .now, monthPaused: paused)
        case .exhausted:
            AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: 0, startsAt: .now, monthPaused: false)
        case .notStarted:
            AnalysisTrialProxyStatus(mode: .open, unitsRemaining: 5, startsAt: .now, monthPaused: false)
        }
        let seeded: [AnalysisProvider: (AnalysisProviderKey, syncs: Bool)] = seedsGoogleKey
            ? [.google: (AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), syncs: true)]
            : [:]
        // The status cache keeps its last read across launches; each test
        // starts from none.
        UserDefaults.standard.removeObject(forKey: AnalysisTrialStatusCache.preferenceKey)
        let directory = URL.temporaryDirectory.appending(path: "chapters-start-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            analysisPolicy: .fixed(.baked),
            analysisKeys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage(seeded: seeded)),
            analysisKeyNotice: AnalysisKeyNoticeStore(trialStatus: keyNoticeStatus ?? trial),
            analysisRuns: AnalysisRunRecordStore(directory: directory),
            analysisTrialConnection: AnalysisTrialConnection(fixtureStatus: fixtureStatus, isFixture: true),
            allowsAutomaticFeedRefresh: false
        )
        await appModel.analysisKeys.refreshPresences()
        return appModel
    }
}
