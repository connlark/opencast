import Foundation

struct ComparisonMetrics: Codable {
    var input: AudioMetrics
    var output: AudioMetrics
    var loudnessDeltaLU: Double?
    var truePeakDeltaDB: Double?
    var rmsDeltaDB: Double?
}

extension ComparisonMetrics {
    init(input: AudioMetrics, output: AudioMetrics) {
        self.input = input
        self.output = output
        loudnessDeltaLU = Self.delta(output.integratedLUFS, input.integratedLUFS)
        truePeakDeltaDB = Self.delta(output.truePeakDBTP, input.truePeakDBTP)
        rmsDeltaDB = Self.delta(output.rmsDBFS, input.rmsDBFS)
    }

    private static func delta(_ output: Double?, _ input: Double?) -> Double? {
        guard let output, let input else {
            return nil
        }
        return output - input
    }
}
