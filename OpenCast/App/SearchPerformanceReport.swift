import Foundation

nonisolated struct SearchPerformanceReport: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
    }

    struct TimingSample: Codable, Sendable {
        let sampleID: String
        let durationMilliseconds: Double
        let resultCount: Int?
        let cancellationCount: Int?
    }

    struct TimingDistribution: Codable, Sendable {
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
        let samples: [TimingSample]

        init(samples: [TimingSample]) {
            precondition(!samples.isEmpty)
            let durations = samples.map(\.durationMilliseconds).sorted()
            p50Milliseconds = Self.percentile(
                0.50,
                sortedValues: durations
            )
            p95Milliseconds = Self.percentile(
                0.95,
                sortedValues: durations
            )
            p99Milliseconds = Self.percentile(
                0.99,
                sortedValues: durations
            )
            self.samples = samples
        }

        private static func percentile(
            _ probability: Double,
            sortedValues: [Double]
        ) -> Double {
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

    struct TranscriptStorage: Codable, Sendable {
        let audioDurationSeconds: Double
        let segmentCount: Int
        let normalizedSourceByteCount: Int
        let derivedIndexByteDelta: Int
        let derivedBytesPerTranscriptHour: Double
        let derivedToNormalizedSourceRatio: Double
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
    let engineID: String
    let generatorVersion: String
    let generatorSeed: UInt64
    let documentCount: Int
    let normalizedMetadataSourceByteCount: Int
    let warmupCount: Int
    let measuredSampleCount: Int
    let typingDebounceMilliseconds: Int
    let typingInterKeystrokeMilliseconds: Int
    let transcriptUpdateSegmentCount: Int
    let transcriptUpdateAudioDurationSeconds: Double
    var incrementalTyping: TimingDistribution?
    var metadataUpdate: TimingDistribution?
    var transcriptCanonicalAndIndexUpdate: TimingDistribution?
    var transcriptStorage: TranscriptStorage?
}
