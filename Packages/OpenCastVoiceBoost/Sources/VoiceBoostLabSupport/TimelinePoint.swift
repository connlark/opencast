import Foundation

struct TimelinePoint: Codable {
    var timeSeconds: Double
    var inputLUFS: Double?
    var outputLUFS: Double?
    var autoGainDB: Double
    var compressorReductionDB: Double
    var limiterReductionDB: Double
    var inputTruePeakDBTP: Double?
    var outputTruePeakDBTP: Double?
}

extension Array where Element == TimelinePoint {
    func csvString() -> String {
        var lines = [
            "timeSeconds,inputLUFS,outputLUFS,autoGainDB,compressorReductionDB,limiterReductionDB,inputTruePeakDBTP,outputTruePeakDBTP"
        ]

        lines += map { point in
            [
                point.timeSeconds.csvField,
                point.inputLUFS.csvField,
                point.outputLUFS.csvField,
                point.autoGainDB.csvField,
                point.compressorReductionDB.csvField,
                point.limiterReductionDB.csvField,
                point.inputTruePeakDBTP.csvField,
                point.outputTruePeakDBTP.csvField
            ].joined(separator: ",")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

private extension Optional where Wrapped == Double {
    var csvField: String {
        guard let unwrapped = self, unwrapped.isFinite else {
            return ""
        }
        return unwrapped.csvField
    }
}

private extension Double {
    var csvField: String {
        formatted(.number.precision(.fractionLength(6)))
    }
}
