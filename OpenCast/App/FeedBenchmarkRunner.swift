import Darwin
import CryptoKit
import Foundation
import OpenCastCore
import SwiftData
import UIKit

/// Explicit launch-only Release probe using the normal subscription, cache,
/// identity, search and library publication path. Captures stay outside app
/// resources and the benchmark's report is device-local.
enum FeedBenchmarkRunner {
    static let requestArgument = "--opencast-run-feed-benchmark"

    static func runIfRequested(library: LibraryStore, modelContext: ModelContext) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(requestArgument) else { return }
        let label = BenchmarkHarnessSupport.argumentValue(from: arguments, flag: "--opencast-feed-benchmark-label") ?? "feed"
        let directory = URL.applicationSupportDirectory.appending(path: "OpenCastFeedBenchmark", directoryHint: .isDirectory)
        let reportURL = directory.appending(path: "\(BenchmarkHarnessSupport.safeStem(label)).json")
        var report = FeedBenchmarkReport(label: label, device: BenchmarkHarnessSupport.machineIdentifier(),
                                         buildMode: BenchmarkHarnessSupport.buildMode)
        let memory = MemoryFootprintSampler()
        let mainActor = FeedMainActorSampler()
        var sampling = false
        do {
            try BenchmarkHarnessSupport.prepareReportDirectory(directory)
            guard BenchmarkHarnessSupport.buildMode == "Release" else {
                throw FeedBenchmarkError("Feed benchmarks require an optimized Release build.")
            }
            guard let rawURL = BenchmarkHarnessSupport.argumentValue(from: arguments, flag: "--opencast-feed-benchmark-url"),
                  let url = URL(string: rawURL) else { throw FeedBenchmarkError("A feed replay URL is required.") }
            let canonicalURL = BenchmarkHarnessSupport.argumentValue(from: arguments, flag: "--opencast-feed-benchmark-canonical-url")
                .flatMap(URL.init(string:)) ?? url
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            if arguments.contains("--opencast-feed-benchmark-reset-synthetic") {
                guard canonicalURL.absoluteString == "https://example.com/opencast-stress-100000.xml" else {
                    throw FeedBenchmarkError("Only the generated stress catalog can be reset by this probe.")
                }
                try await library.localCache.deleteCache(forPodcastID: URLCanonicalizer.podcastID(for: canonicalURL).rawValue)
                try await library.reloadFromStore(modelContext: modelContext)
            }
            try await library.localCache.prepareEpisodeSearchIndex()
            report.phase = "transferring"
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
            report.footprintStartBytes = MemoryFootprintSampler.currentFootprintBytes()
            memory.start()
            mainActor.start()
            sampling = true
            let transferStart = ContinuousClock.now
            var transfer: OpenCastHTTPFileResult?
            defer { withExtendedLifetime(transfer) {} }
            let source: URL
            if let filename = BenchmarkHarnessSupport.argumentValue(from: arguments, flag: "--opencast-feed-benchmark-file") {
                guard filename == (filename as NSString).lastPathComponent else {
                    throw FeedBenchmarkError("Use a file copied into OpenCastFeedFixtures.")
                }
                source = URL.applicationSupportDirectory.appending(path: "OpenCastFeedFixtures", directoryHint: .isDirectory)
                    .appending(path: filename)
                let proof = try await fixtureProof(source)
                report.decodedBytes = proof.bytes
                report.bodyHash = proof.hash
            } else {
                let client = URLSessionOpenCastHTTPClient(configuration: OpenCastURLSessionFactory.feedConfiguration())
                let result = try await client.feedFile(for: URLRequest(url: url), maximumBodyByteCount: FeedResourcePolicy.maximumDecodedBytes)
                transfer = result
                source = result.fileURL
                report.decodedBytes = result.decodedByteCount
                report.bodyHash = result.bodyHash
            }
            report.transferSeconds = seconds(transferStart.duration(to: .now))
            report.phase = "preparing"
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
            let preparationStart = ContinuousClock.now
            let prepared = try await RSSFeedParser().prepare(fileURL: source, feedURL: canonicalURL,
                                                           transferIssue: transfer?.incompleteReason)
            report.preparationSeconds = seconds(preparationStart.duration(to: .now))
            report.phase = "importing"
            report.sampledPeakBytes = MemoryFootprintSampler.currentFootprintBytes()
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
            let importStart = ContinuousClock.now
            try await library.subscribe(prepared: prepared, modelContext: modelContext)
            report.importAndPublicationSeconds = seconds(importStart.duration(to: .now))
            report.processingSeconds = seconds(preparationStart.duration(to: .now))
            report.sampledPeakBytes = memory.stop()
            report.processLifetimePeakBytes = processPeakFootprint()
            report.maximumMainActorDelaySeconds = await mainActor.stop()
            sampling = false
            report.episodeCount = prepared.episodeCount
            let cached = library.episodes(forPodcastID: prepared.podcast.id.rawValue)
            report.cachedCount = cached.count
            report.newestEpisodeID = cached.first?.episodeID
            report.oldestEpisodeID = cached.last?.episodeID
            report.completeness = prepared.completeness
            report.phase = "complete"
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        } catch {
            if sampling {
                report.sampledPeakBytes = memory.stop()
                report.maximumMainActorDelaySeconds = await mainActor.stop()
            }
            report.phase = "failed"
            report.error = error.localizedDescription
            try? BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        }
    }

    @concurrent
    private static func fixtureProof(_ url: URL) async throws -> (bytes: Int, hash: String) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        var count = 0
        while let chunk = try file.read(upToCount: FeedResourcePolicy.chunkBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            digest.update(data: chunk)
        }
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func processPeakFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.ledger_phys_footprint_peak : nil
    }
}

private struct FeedBenchmarkReport: Encodable {
    let label: String
    let device: String
    let buildMode: String
    var phase = "starting"
    var error: String?
    var decodedBytes: Int?
    var bodyHash: String?
    var transferSeconds: Double?
    var preparationSeconds: Double?
    var importAndPublicationSeconds: Double?
    var processingSeconds: Double?
    var footprintStartBytes: Int64?
    var sampledPeakBytes: Int64?
    var processLifetimePeakBytes: Int64?
    var maximumMainActorDelaySeconds: Double?
    var episodeCount: Int?
    var cachedCount: Int?
    var newestEpisodeID: String?
    var oldestEpisodeID: String?
    var completeness: FeedCompleteness?
}

private struct FeedBenchmarkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
