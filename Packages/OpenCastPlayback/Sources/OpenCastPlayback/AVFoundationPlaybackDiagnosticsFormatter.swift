@preconcurrency import AVFoundation
import Foundation

enum AVFoundationPlaybackDiagnosticsFormatter {
    static func text(
        snapshot: PlaybackSnapshot,
        player: AVPlayer,
        item: AVPlayerItem?,
        isPlaybackRequested: Bool,
        isAudioSessionActive: Bool,
        protectedPlaybackPosition: TimeInterval?,
        automaticTransientFailureRetryCount: Int,
        automaticTransientFailureRetryLimit: Int,
        streamingAudioCacheConfiguration: StreamingAudioCacheConfiguration,
        currentStreamingPlayerItem: AVPlayerItem?,
        currentStreamingFallbackURL: URL?,
        hasAttemptedStreamingCacheFallback: Bool,
        events: [String]
    ) -> String {
        var lines: [String] = [
            "opencast Playback Diagnostics",
            "updated: \(Date.now.formatted(.dateTime.year().month().day().hour().minute().second()))",
            "",
            "episode.id: \(snapshot.currentEpisode?.id.rawValue ?? "nil")",
            "episode.podcastID: \(snapshot.currentEpisode?.podcastID.rawValue ?? "nil")",
            "episode.title: \(snapshot.currentEpisode?.title ?? "nil")",
            "episode.audioURL: \(snapshot.currentEpisode?.audioURL?.absoluteString ?? "nil")",
            "",
            "state: \(description(for: snapshot.state))",
            "isPlaybackRequested: \(isPlaybackRequested)",
            "isAudioSessionActive: \(isAudioSessionActive)",
            "rate: \(snapshot.rate)",
            "position: \(time(snapshot.position))",
            "duration: \(time(snapshot.duration))",
            "progress: \(snapshot.normalizedProgress.formatted(.number.precision(.fractionLength(4))))",
            "progressBoundaryID: \(snapshot.progressBoundaryID)",
            "protectedPlaybackPosition: \(time(protectedPlaybackPosition))",
            "failureRecovery.automaticTransientRetries: \(automaticTransientFailureRetryCount)/\(automaticTransientFailureRetryLimit)",
            "",
            "streaming.mode: \(streamingModeDescription(for: item, currentStreamingPlayerItem: currentStreamingPlayerItem))",
            "streaming.cache.enabled: \(streamingAudioCacheConfiguration.isEnabled)",
            "streaming.cache.directory: \(streamingAudioCacheConfiguration.directory?.path ?? "nil")",
            "streaming.cache.fallbackURL: \(currentStreamingFallbackURL?.absoluteString ?? "nil")",
            "streaming.cache.attemptedFallback: \(hasAttemptedStreamingCacheFallback)",
            "",
            "player.timeControlStatus: \(timeControlStatus(player.timeControlStatus))",
            "player.reasonForWaitingToPlay: \(player.reasonForWaitingToPlay?.rawValue ?? "nil")",
            "player.rate: \(player.rate)",
            "player.currentTime: \(time(player.currentTime().seconds))",
            "player.error: \(description(for: player.error))",
            "",
            "item.status: \(description(for: item?.status))",
            "item.duration: \(time(item?.duration.seconds))",
            "item.isPlaybackBufferEmpty: \(item?.isPlaybackBufferEmpty.description ?? "nil")",
            "item.isPlaybackLikelyToKeepUp: \(item?.isPlaybackLikelyToKeepUp.description ?? "nil")",
            "item.isPlaybackBufferFull: \(item?.isPlaybackBufferFull.description ?? "nil")",
            "item.error: \(description(for: item?.error))"
        ]

        appendTimeRanges(item?.loadedTimeRanges ?? [], title: "item.loadedTimeRanges", to: &lines)
        appendTimeRanges(item?.seekableTimeRanges ?? [], title: "item.seekableTimeRanges", to: &lines)
        appendErrorLog(item?.errorLog(), to: &lines)
        appendAccessLog(item?.accessLog(), to: &lines)

        lines.append("")
        lines.append("events:")
        if events.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: events.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    static func time(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else {
            return "nil"
        }

        return value.formatted(.number.precision(.fractionLength(3)))
    }

    static func timeControlStatus(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused:
            return "paused"
        case .waitingToPlayAtSpecifiedRate:
            return "waitingToPlayAtSpecifiedRate"
        case .playing:
            return "playing"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    static func errorSummary(for error: (any Error)?) -> String {
        guard let error else {
            return "nil"
        }

        var parts: [String] = []
        var currentError: (any Error)? = error
        while let error = currentError {
            let nsError = error as NSError
            parts.append(
                "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
            )
            currentError = nsError.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return parts.joined(separator: " underlying=")
    }

    static func errorLogSummary(for event: AVPlayerItemErrorLogEvent) -> String {
        let date = event.date?.formatted(.dateTime.hour().minute().second()) ?? "nil"
        return "date=\(date) status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(event.errorComment ?? "nil")"
    }

    static func accessLogSummary(for event: AVPlayerItemAccessLogEvent) -> String {
        "requests=\(event.numberOfMediaRequests) bytes=\(event.numberOfBytesTransferred) stalls=\(event.numberOfStalls) observedBitrate=\(number(event.observedBitrate)) indicatedBitrate=\(number(event.indicatedBitrate)) transferDuration=\(time(event.transferDuration))"
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else {
            return "nil"
        }

        return value.formatted(.number.precision(.fractionLength(3)))
    }

    private static func appendTimeRanges(_ ranges: [NSValue], title: String, to lines: inout [String]) {
        lines.append("")
        lines.append("\(title):")
        guard !ranges.isEmpty else {
            lines.append("- none")
            return
        }

        for rangeValue in ranges {
            let range = rangeValue.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            lines.append("- start=\(time(start)) duration=\(time(duration)) end=\(time(start + duration))")
        }
    }

    private static func appendErrorLog(_ errorLog: AVPlayerItemErrorLog?, to lines: inout [String]) {
        lines.append("")
        lines.append("item.errorLog:")
        guard let events = errorLog?.events, !events.isEmpty else {
            lines.append("- none")
            return
        }

        for event in events.suffix(8) {
            lines.append("- \(errorLogSummary(for: event))")
        }
    }

    private static func appendAccessLog(_ accessLog: AVPlayerItemAccessLog?, to lines: inout [String]) {
        lines.append("")
        lines.append("item.accessLog:")
        guard let events = accessLog?.events, !events.isEmpty else {
            lines.append("- none")
            return
        }

        for event in events.suffix(5) {
            lines.append("- \(accessLogSummary(for: event))")
        }
    }

    private static func streamingModeDescription(
        for item: AVPlayerItem?,
        currentStreamingPlayerItem: AVPlayerItem?
    ) -> String {
        if let item, currentStreamingPlayerItem === item {
            return "byte-range cache resource loader"
        }

        return "direct AVPlayer streaming"
    }

    private static func description(for state: PlaybackState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .loading:
            return "loading"
        case .buffering:
            return "buffering"
        case .paused:
            return "paused"
        case .playing:
            return "playing"
        case .failed(let message):
            return "failed(\(message))"
        }
    }

    private static func description(for status: AVPlayerItem.Status?) -> String {
        guard let status else {
            return "nil"
        }

        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    private static func description(for error: (any Error)?) -> String {
        errorSummary(for: error)
    }
}
