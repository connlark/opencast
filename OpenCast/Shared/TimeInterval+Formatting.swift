import Foundation

extension TimeInterval {
    nonisolated var formattedPlaybackDuration: String {
        formattedPlaybackDuration(locale: .current)
    }

    nonisolated func formattedPlaybackDuration(locale: Locale) -> String {
        guard isFinite else {
            return "0:00"
        }

        let totalSeconds = floor(max(self, 0))
        let hours = floor(totalSeconds / 3_600)
        let minutes = Int(totalSeconds.truncatingRemainder(dividingBy: 3_600) / 60)
        let seconds = Int(totalSeconds.truncatingRemainder(dividingBy: 60))
        let padded = IntegerFormatStyle<Int>(locale: locale)
            .grouping(.never)
            .precision(.integerLength(2...))

        if hours > 0 {
            let hourStyle = FloatingPointFormatStyle<Double>(locale: locale)
                .grouping(.never)
                .precision(.fractionLength(0))
            return "\(hours.formatted(hourStyle)):\(minutes.formatted(padded)):\(seconds.formatted(padded))"
        }

        let minuteStyle = IntegerFormatStyle<Int>(locale: locale).grouping(.never)
        return "\(minutes.formatted(minuteStyle)):\(seconds.formatted(padded))"
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
