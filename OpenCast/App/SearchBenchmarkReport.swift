import Foundation

nonisolated struct SearchBenchmarkReport: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
    }

    struct Sample: Codable, Sendable {
        let queryID: String
        let durationMilliseconds: Double
        let resultCount: Int
        let topEpisodeIDs: [String]
    }

    struct EngineRun: Codable, Sendable {
        let engineID: String
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
        let preparationMilliseconds: Double?
        let databaseBytesBeforePreparation: Int?
        let databaseBytesAfterPreparation: Int?
        let derivedIndexByteDelta: Int?
        let residentMemoryBytesAtStart: Int64?
        let peakResidentMemoryBytes: Int64?
        let residentMemoryByteIncrease: Int64?
        let samples: [Sample]
    }

    struct CorpusRun: Codable, Sendable {
        let documentCount: Int
        let normalizedSourceByteCount: Int
        let corpusSHA256: String
        let engines: [EngineRun]
    }

    var status: Status
    let recordedAt: Date
    var completedAt: Date?
    var errorMessage: String?
    let buildMode: String
    let operatingSystem: String
    let hardwareModel: String
    let simulatorUDID: String?
    let thermalState: String
    let runKind: String
    let generatorVersion: String
    let generatorSeed: UInt64
    let warmupCountPerEngine: Int
    let measuredQueryCountPerEngine: Int
    var corpora: [CorpusRun]

    static func engineRun(
        engineID: String,
        samples: [Sample],
        preparationMilliseconds: Double? = nil,
        databaseBytesBeforePreparation: Int? = nil,
        databaseBytesAfterPreparation: Int? = nil,
        residentMemory: ProcessResidentMemorySampler.Measurement? = nil
    ) -> EngineRun {
        let durations = samples.map(\.durationMilliseconds).sorted()
        let derivedIndexByteDelta: Int? = if let databaseBytesBeforePreparation,
                                            let databaseBytesAfterPreparation {
            max(
                0,
                databaseBytesAfterPreparation
                    - databaseBytesBeforePreparation
            )
        } else {
            nil
        }
        return EngineRun(
            engineID: engineID,
            p50Milliseconds: percentile(0.50, sortedValues: durations),
            p95Milliseconds: percentile(0.95, sortedValues: durations),
            p99Milliseconds: percentile(0.99, sortedValues: durations),
            preparationMilliseconds: preparationMilliseconds,
            databaseBytesBeforePreparation: databaseBytesBeforePreparation,
            databaseBytesAfterPreparation: databaseBytesAfterPreparation,
            derivedIndexByteDelta: derivedIndexByteDelta,
            residentMemoryBytesAtStart: residentMemory?.bytesAtStart,
            peakResidentMemoryBytes: residentMemory?.peakBytes,
            residentMemoryByteIncrease: residentMemory?.increaseBytes,
            samples: samples
        )
    }

    private static func percentile(
        _ probability: Double,
        sortedValues: [Double]
    ) -> Double {
        precondition(!sortedValues.isEmpty)
        let position = probability * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else {
            return sortedValues[lowerIndex]
        }
        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex] * (1 - fraction)
            + sortedValues[upperIndex] * fraction
    }
}
