import Foundation
import OpenCastCore

/// Opt-in Release-capable harness for the process-cold first-usable gate.
/// It uses a dedicated cache database and never changes the user's cache.
/// Flags resolve through `OpenCastLaunchConfiguration`, the launch-flag seam.
enum SearchColdStartProbe {
    static let probeArgument = "--opencast-run-search-cold-start-probe"
    static let seedArgument = "--opencast-seed-search-cold-start-corpus"
    static let disablePreparationArgument =
        "--opencast-disable-search-index-preparation"
    static let labelArgument = "--opencast-search-cold-start-label"

    private static var processStartUptimeNanoseconds: UInt64?
    private static var hasWrittenFirstUsable = false

    static var usesDedicatedDatabase: Bool {
        let configuration = OpenCastLaunchConfiguration.current
        return configuration.runsSearchColdStartProbe
            || configuration.seedsSearchColdStartCorpus
    }

    static var disablesSearchIndexPreparation: Bool {
        let configuration = OpenCastLaunchConfiguration.current
        return configuration.disablesSearchIndexPreparation
            || configuration.seedsSearchColdStartCorpus
    }

    static var dedicatedDatabaseURL: URL? {
        guard usesDedicatedDatabase else { return nil }
        return outputDirectory.appending(path: "cold-start-corpus.sqlite")
    }

    static func recordProcessStart() {
        processStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    static func recordFirstUsableIfRequested() {
        let configuration = OpenCastLaunchConfiguration.current
        guard configuration.runsSearchColdStartProbe,
              !hasWrittenFirstUsable,
              let processStartUptimeNanoseconds
        else {
            return
        }
        hasWrittenFirstUsable = true
        let end = DispatchTime.now().uptimeNanoseconds
        let elapsedMilliseconds = Double(
            end &- processStartUptimeNanoseconds
        ) / 1_000_000
        let label = configuration.searchColdStartProbeLabel ?? "unlabeled"
        do {
            try BenchmarkHarnessSupport.prepareReportDirectory(outputDirectory)
            try BenchmarkHarnessSupport.writeJSONReport(
                FirstUsableReport(
                    label: label,
                    measuredAt: .now,
                    elapsedMilliseconds: elapsedMilliseconds,
                    searchIndexPreparationEnabled:
                        !disablesSearchIndexPreparation,
                    osVersion: ProcessInfo.processInfo
                        .operatingSystemVersionString,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
                ),
                to: outputDirectory.appending(
                    path: "cold-start-\(BenchmarkHarnessSupport.safeStem(label))-\(UUID().uuidString).json"
                )
            )
        } catch {
            // Measurement must never affect app usability.
        }
    }

    static func seedIfRequested(
        store: any LocalLibraryCacheStore
    ) async {
        guard OpenCastLaunchConfiguration.current.seedsSearchColdStartCorpus
        else {
            return
        }
        do {
            try BenchmarkHarnessSupport.prepareReportDirectory(outputDirectory)
            let corpus = SearchBenchmarkCorpusGenerator.make(
                documentCount: 25_000
            )
            for snapshot in SearchBenchmarkRunner.feedSnapshots(
                from: corpus.documents
            ) {
                try await store.upsertCache(from: snapshot, refreshedAt: .now)
            }
            try await store.prepareEpisodeSearchIndex()
            try BenchmarkHarnessSupport.writeJSONReport(
                SeedReport(
                    completedAt: .now,
                    documentCount: corpus.documents.count,
                    normalizedSourceByteCount:
                        corpus.normalizedSourceByteCount,
                    corpusSHA256: corpus.sha256
                ),
                to: outputDirectory.appending(path: "cold-start-seed.json")
            )
        } catch {
            try? BenchmarkHarnessSupport.prepareReportDirectory(outputDirectory)
            try? BenchmarkHarnessSupport.writeJSONReport(
                SeedFailureReport(
                    completedAt: .now,
                    errorMessage: error.localizedDescription
                ),
                to: outputDirectory.appending(
                    path: "cold-start-seed-failed.json"
                )
            )
        }
    }

    private static var outputDirectory: URL {
        URL.applicationSupportDirectory.appending(
            path: "OpenCastSearchColdStart",
            directoryHint: .isDirectory
        )
    }

    private struct FirstUsableReport: Codable {
        let label: String
        let measuredAt: Date
        let elapsedMilliseconds: Double
        let searchIndexPreparationEnabled: Bool
        let osVersion: String
        let physicalMemoryBytes: UInt64
    }

    private struct SeedReport: Codable {
        let completedAt: Date
        let documentCount: Int
        let normalizedSourceByteCount: Int
        let corpusSHA256: String
    }

    private struct SeedFailureReport: Codable {
        let completedAt: Date
        let errorMessage: String
    }
}
