import Foundation

extension TimeInterval {
    var formattedPlaybackDuration: String {
        guard isFinite else {
            return "0:00"
        }

        let totalSeconds = max(Int(self), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let padded = IntegerFormatStyle<Int>().precision(.integerLength(2))

        if hours > 0 {
            return "\(hours):\(minutes.formatted(padded)):\(seconds.formatted(padded))"
        }

        return "\(minutes):\(seconds.formatted(padded))"
    }

    var formattedEpisodeRemaining: String {
        guard isFinite else {
            return "0m left"
        }

        let totalMinutes = max(Int(ceil(max(self, 0) / 60)), 1)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m left"
        }

        if hours > 0 {
            return "\(hours)h left"
        }

        return "\(totalMinutes)m left"
    }
}

extension Float {
    var formattedSpeed: String {
        self == 1 ? "1x" : "\(self)x"
    }
}
