import Foundation

/// Records a frame-pacing marker for the Now Playing presentation probe.
///
/// No-op unless the DEBUG frame probe is enabled (`--opencast-frame-probe` /
/// `OPENCAST_FRAME_PROBE=1`). Used to measure presentation smoothness independent
/// of screen recording, which warms the compositor and masks first-frame stalls.
@inline(__always)
func nowPlayingProbeMark(_ label: String) {
    #if DEBUG
    NowPlayingFramePacingProbe.shared.mark(label)
    #endif
}

#if DEBUG
import QuartzCore
import os

final class NowPlayingFramePacingProbe: NSObject {
    static let shared = NowPlayingFramePacingProbe()

    private let logger = Logger(subsystem: "com.connor.opencast.perf", category: "framepacing")
    private static let signposter = OSSignposter(
        subsystem: "com.connor.opencast.perf",
        category: "NowPlaying"
    )

    private(set) var isEnabled = false
    /// Flushed per-session summary lines, exposed to UI tests via accessibility
    /// because xcodebuild runs tests on an ephemeral simulator clone whose
    /// container is unreadable from the host.
    private(set) var sessionSummaries: [String] = []
    private var displayLink: CADisplayLink?
    private var frames: [Double] = []
    private var events: [(label: String, time: Double)] = []
    private var flushDeadline: Double?
    private var sessionIndex = 0

    private static let flushQuietWindow = 1.5
    private static let analysisTail = 0.30

    func enableIfRequested() {
        let args = Set(CommandLine.arguments)
        let env = ProcessInfo.processInfo.environment
        isEnabled = args.contains("--opencast-frame-probe") || env["OPENCAST_FRAME_PROBE"] == "1"
        guard isEnabled, displayLink == nil else {
            return
        }

        frames.reserveCapacity(16_384)
        let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        logger.log("frame probe enabled")
    }

    func mark(_ label: String) {
        guard isEnabled else {
            return
        }

        events.append((label, CACurrentMediaTime()))
        Self.signposter.emitEvent("mark", "\(label, privacy: .public)")
        flushDeadline = CACurrentMediaTime() + Self.flushQuietWindow
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        frames.append(link.timestamp)
        if frames.count > 16_384 {
            frames.removeFirst(frames.count - 16_384)
        }

        if let deadline = flushDeadline, link.timestamp >= deadline {
            flushDeadline = nil
            flush()
        }
    }

    private func flush() {
        guard let firstEvent = events.first, let lastEvent = events.last, frames.count > 2 else {
            events.removeAll(keepingCapacity: true)
            return
        }

        sessionIndex += 1
        let origin = firstEvent.time
        let windowStart = firstEvent.time
        let windowEnd = lastEvent.time + Self.analysisTail

        // Inter-frame deltas whose end timestamp falls inside the analysis window.
        var deltas: [(end: Double, delta: Double)] = []
        deltas.reserveCapacity(frames.count)
        for index in 1..<frames.count {
            let end = frames[index]
            guard end >= windowStart, end <= windowEnd else {
                continue
            }
            deltas.append((end, frames[index] - frames[index - 1]))
        }

        guard !deltas.isEmpty else {
            events.removeAll(keepingCapacity: true)
            return
        }

        let sortedDeltaValues = deltas.map(\.delta).sorted()
        let refresh = sortedDeltaValues[sortedDeltaValues.count / 2]
        let maxDelta = sortedDeltaValues.last ?? 0
        let over16 = deltas.count { $0.delta > 0.0167 }
        let over33 = deltas.count { $0.delta > 0.0333 }
        let over50 = deltas.count { $0.delta > 0.050 }
        let over100 = deltas.count { $0.delta > 0.100 }

        let topGaps = deltas.sorted { $0.delta > $1.delta }.prefix(6).map { gap -> String in
            let startMs = (gap.end - gap.delta - origin) * 1000
            return String(format: "%.1fms@+%.0f[%@]", gap.delta * 1000, startMs, phase(at: gap.end - gap.delta))
        }

        let eventLine = events.map { String(format: "%@@+%.0f", $0.label, ($0.time - origin) * 1000) }
            .joined(separator: " ")

        let summary = String(
            format: "session=%d frames=%d refresh=%.1fms maxGap=%.1fms >16.7=%d >33=%d >50=%d >100=%d | events: %@ | topGaps: %@",
            sessionIndex, deltas.count, refresh * 1000, maxDelta * 1000,
            over16, over33, over50, over100, eventLine, topGaps.joined(separator: ", ")
        )
        logger.log("\(summary, privacy: .public)")
        sessionSummaries.append(summary)
        writeRawLog(sessionIndex: sessionIndex, origin: origin, summary: summary)

        events.removeAll(keepingCapacity: true)
    }

    private func phase(at time: Double) -> String {
        var current = "pre"
        for event in events where event.time <= time {
            current = event.label
        }
        return current
    }

    private func writeRawLog(sessionIndex: Int, origin: Double, summary: String) {
        var lines = ["# \(summary)"]
        for event in events {
            lines.append(String(format: "EVENT %.2f %@", (event.time - origin) * 1000, event.label))
        }
        for index in 1..<frames.count {
            let relEnd = (frames[index] - origin) * 1000
            guard relEnd >= -10 else {
                continue
            }
            lines.append(String(format: "FRAME %.2f %.3f", relEnd, (frames[index] - frames[index - 1]) * 1000))
        }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("opencast-framepacing-\(sessionIndex).log")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
