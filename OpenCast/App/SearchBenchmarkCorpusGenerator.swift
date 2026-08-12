import CryptoKit
import Foundation

nonisolated enum SearchBenchmarkCorpusGenerator {
    static let version = "search-scaling-corpus-v1"
    static let seed: UInt64 = 736_628_931

    struct Document: Sendable {
        let episodeID: String
        let podcastID: String
        let podcastTitle: String
        let title: String
        let summaryHTML: String
        let showNotesHTML: String
        let publishedAt: Date
    }

    struct Query: Sendable {
        let identifier: String
        let text: String
        let mode: EpisodeSearchMode
    }

    struct Corpus: Sendable {
        let documents: [Document]
        let queries: [Query]
        let normalizedSourceByteCount: Int
        let sha256: String
    }

    static func make(documentCount: Int) -> Corpus {
        precondition(documentCount >= 1_000)
        var generator = SplitMix64(state: seed ^ UInt64(documentCount))
        let vocabulary = [
            "acoustic", "archive", "bearing", "canopy", "ceramic", "channel", "circuit", "coastal",
            "compass", "current", "detector", "drainage", "fermentation", "field", "frequency", "garden",
            "glacier", "harbor", "instrument", "lantern", "magnetic", "membrane", "migration", "midnight",
            "navigation", "notebook", "observation", "orchard", "pattern", "pollinator", "pressure", "receiver",
            "repair", "research", "resonance", "river", "sensor", "signal", "sleep", "species",
            "spectrum", "temperature", "thermal", "transcript", "workshop", "woven", "astronomy", "botany",
            "calibration", "coral", "history", "language", "memory", "microphone", "network", "optical",
            "punctuation", "radio", "sequence", "spacing", "transmission", "weather", "wetland", "wildlife"
        ]

        var documents: [Document] = []
        documents.reserveCapacity(documentCount)
        var sourceByteCount = 0
        var digestInput = Data()

        for index in 0..<documentCount {
            let podcastIndex = index % max(20, documentCount / 40)
            let podcastID = "benchmark-feed-\(podcastIndex)"
            var podcastTitle = "Field Archive \(podcastIndex)"
            var title = "Episode \(index): \(words(count: 5, vocabulary: vocabulary, generator: &generator))"
            var summary = words(
                count: 42 + generator.nextInt(upperBound: 36),
                vocabulary: vocabulary,
                generator: &generator
            )
            var showNotes = words(
                count: 150 + generator.nextInt(upperBound: 220),
                vocabulary: vocabulary,
                generator: &generator
            )

            applySpecialFixture(
                index: index,
                podcastTitle: &podcastTitle,
                title: &title,
                summary: &summary,
                showNotes: &showNotes
            )

            let episodeID = "benchmark-episode-\(index)"
            let summaryHTML = "<p>\(summary)</p>"
            let showNotesHTML = "<p>\(showNotes)</p>"
            let publishedAt = Date(
                timeIntervalSince1970: 1_500_000_000 + TimeInterval(index * 1_800)
            )
            documents.append(
                Document(
                    episodeID: episodeID,
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: title,
                    summaryHTML: summaryHTML,
                    showNotesHTML: showNotesHTML,
                    publishedAt: publishedAt
                )
            )

            sourceByteCount += episodeID.utf8.count
                + podcastID.utf8.count
                + podcastTitle.utf8.count
                + title.utf8.count
                + summary.utf8.count
                + showNotes.utf8.count
            digestInput.append(contentsOf: episodeID.utf8)
            digestInput.append(0)
            digestInput.append(contentsOf: podcastTitle.utf8)
            digestInput.append(0)
            digestInput.append(contentsOf: title.utf8)
            digestInput.append(0)
            digestInput.append(contentsOf: summary.utf8)
            digestInput.append(0)
            digestInput.append(contentsOf: showNotes.utf8)
            digestInput.append(0)
        }

        let digest = SHA256.hash(data: digestInput)
            .map { String(format: "%02x", $0) }
            .joined()
        return Corpus(
            documents: documents,
            queries: queries,
            normalizedSourceByteCount: sourceByteCount,
            sha256: digest
        )
    }

    private static let queries = [
        Query(identifier: "exact-orchard", text: "orchard midnight", mode: .fullText),
        Query(identifier: "exact-keyboard", text: "keyboard membrane", mode: .fullText),
        Query(identifier: "person-ada", text: "ada lovelace", mode: .fullText),
        Query(identifier: "show-signal-loom", text: "signal loom", mode: .episodes),
        Query(identifier: "summary-thermal", text: "thermal anomaly", mode: .fullText),
        Query(identifier: "notes-radical-pairs", text: "cryptochrome radical pairs", mode: .fullText),
        Query(identifier: "notes-index-mirror", text: "index mirror error", mode: .fullText),
        Query(identifier: "person-mira", text: "mira okafor", mode: .fullText),
        Query(identifier: "summary-conductive", text: "conductive ink", mode: .fullText),
        Query(identifier: "summary-antenna", text: "directional antenna", mode: .fullText),
        Query(identifier: "common-field", text: "field observation", mode: .fullText),
        Query(identifier: "number-date", text: "episode 42 april 17", mode: .fullText),
        Query(identifier: "accent-cafe", text: "cafe noir", mode: .fullText),
        Query(identifier: "cjk-tokyo", text: "東京 庭", mode: .fullText),
        Query(identifier: "punctuation-cpp", text: "C++ C#", mode: .episodes),
        Query(identifier: "typo-keyboard", text: "keybaord membrane", mode: .fullText),
        Query(identifier: "prefix-orch", text: "orch", mode: .episodes),
        Query(identifier: "no-result", text: "quantum banana upholstery", mode: .fullText),
        Query(identifier: "hostile-syntax", text: "\"OR\" NEAR(5) *", mode: .fullText),
        Query(identifier: "frequent-archive", text: "archive", mode: .fullText)
    ]

    private static func applySpecialFixture(
        index: Int,
        podcastTitle: inout String,
        title: inout String,
        summary: inout String,
        showNotes: inout String
    ) {
        switch index {
        case 0:
            title = "The Orchard at Midnight"
            summary += " A field recording follows moth navigation through a pear orchard."
        case 1:
            title = "Repairing a Keyboard Membrane"
            summary += " Conductive ink restores the keyboard matrix."
        case 2:
            title = "Ada Lovelace in the Margin"
            summary += " Ada Lovelace revises notes about a calculating engine."
        case 3:
            podcastTitle = "Signal & Loom"
            title = "A Woven Binary Pattern"
        case 4:
            title = "A Deep Reef Field Guide"
            summary += " Mesophotic bleaching follows a thermal anomaly at depth."
        case 5:
            title = "How a Night Bird Finds North"
            showNotes += " Cryptochrome radical pairs may respond to a magnetic field."
        case 6:
            title = "The Brass Sextant"
            showNotes += " An index mirror error shifts every measured altitude."
        case 7:
            title = "Mira Okafor Maps a Quiet Square"
            summary += " Mira Okafor places each microphone beneath a stone arcade."
        case 8:
            title = "Conductive Ink at the Workbench"
            summary += " Carbon contacts and conductive ink repair a membrane trace."
        case 9:
            title = "A Shortwave Radio Wakes Up"
            summary += " A directional antenna helps locate interference."
        case 10:
            title = "Episode 42: The April 17 Sequence"
            summary += " The sequence aired on April 17 2026."
        case 11:
            title = "Café Noir and Memory"
            summary += " Slow sleep and memory are discussed over coffee."
        case 12:
            title = "東京の小さな庭"
            summary += " 東京の路地にある小さな庭と雨の音。"
        case 13:
            title = "C++ & C#: Punctuation in Names"
            summary += " Search tokenizers meet C++ and C#."
        default:
            break
        }
    }

    private static func words(
        count: Int,
        vocabulary: [String],
        generator: inout SplitMix64
    ) -> String {
        (0..<count)
            .map { _ in vocabulary[generator.nextInt(upperBound: vocabulary.count)] }
            .joined(separator: " ")
    }

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func nextInt(upperBound: Int) -> Int {
            Int(next() % UInt64(upperBound))
        }
    }
}
