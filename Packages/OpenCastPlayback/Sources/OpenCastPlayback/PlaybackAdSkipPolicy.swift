import Foundation

public nonisolated struct PlaybackAdSkipPolicy: Sendable, Equatable {
    public nonisolated enum EvaluationCause: Sendable, Equatable {
        case acceptedTick
        case seekLanding(PlaybackSeekIntent)
        case playStart
    }

    public nonisolated enum Command: Sendable, Equatable {
        case skip(to: TimeInterval, zoneID: Int)
    }

    public private(set) var zones: [PlaybackSkipZone]
    public private(set) var isEnabled: Bool
    private var disarmedZoneID: Int?

    public init(zones: [PlaybackSkipZone] = [], isEnabled: Bool = true) {
        self.zones = Self.normalizedZones(zones)
        self.isEnabled = isEnabled
    }

    public mutating func setZones(_ zones: [PlaybackSkipZone]) {
        self.zones = Self.normalizedZones(zones)
        disarmedZoneID = nil
    }

    public mutating func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public mutating func evaluate(
        previousPosition: TimeInterval?,
        position: TimeInterval,
        duration: TimeInterval?,
        cause: EvaluationCause
    ) -> Command? {
        guard isEnabled, position.isFinite else {
            return nil
        }

        refreshDisarm(at: position)

        switch cause {
        case .acceptedTick, .playStart:
            return evaluateEntry(
                previousPosition: previousPosition,
                position: position,
                duration: duration
            )
        case .seekLanding(let intent):
            return evaluateSeekLanding(
                position: position,
                duration: duration,
                intent: intent
            )
        }
    }

    private mutating func evaluateEntry(
        previousPosition: TimeInterval?,
        position: TimeInterval,
        duration: TimeInterval?
    ) -> Command? {
        guard let containingZone = zone(containing: position),
              containingZone.id != disarmedZoneID
        else {
            return nil
        }

        if let previousPosition {
            if let previousZone = zone(containing: previousPosition),
               previousZone.id == containingZone.id
            {
                return nil
            }

            if previousPosition < containingZone.startTime, position >= containingZone.endTime {
                return nil
            }
        }

        return makeSkipCommand(for: containingZone, from: position, duration: duration)
    }

    private mutating func evaluateSeekLanding(
        position: TimeInterval,
        duration: TimeInterval?,
        intent: PlaybackSeekIntent
    ) -> Command? {
        guard let zone = zone(containing: position) else {
            return nil
        }

        switch intent {
        case .scrub:
            disarmedZoneID = zone.id
            return nil
        case .skipButton, .restore, .autoSkip:
            guard zone.id != disarmedZoneID else {
                return nil
            }
            return makeSkipCommand(for: zone, from: position, duration: duration)
        }
    }

    private mutating func refreshDisarm(at position: TimeInterval) {
        guard let disarmedZoneID,
              let disarmedZone = zones.first(where: { $0.id == disarmedZoneID })
        else {
            self.disarmedZoneID = nil
            return
        }

        if !disarmedZone.contains(position) {
            self.disarmedZoneID = nil
        }
    }

    private func zone(containing position: TimeInterval) -> PlaybackSkipZone? {
        zones.first { $0.contains(position) }
    }

    private mutating func makeSkipCommand(
        for zone: PlaybackSkipZone,
        from position: TimeInterval,
        duration: TimeInterval?
    ) -> Command? {
        let target = clampPlaybackPosition(zone.endTime, to: duration)
        guard target > position else {
            return nil
        }
        disarmedZoneID = zone.id
        return .skip(to: target, zoneID: zone.id)
    }

    private static func normalizedZones(_ zones: [PlaybackSkipZone]) -> [PlaybackSkipZone] {
        let sortedZones = zones
            .filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }
            .sorted {
                if $0.startTime == $1.startTime {
                    if $0.endTime == $1.endTime {
                        return $0.id < $1.id
                    }
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }

        return sortedZones.reduce(into: []) { result, zone in
            guard let last = result.last else {
                result.append(zone)
                return
            }

            if zone.startTime <= last.endTime {
                result[result.endIndex - 1] = PlaybackSkipZone(
                    id: last.id,
                    startTime: last.startTime,
                    endTime: max(last.endTime, zone.endTime)
                )
            } else {
                result.append(zone)
            }
        }
    }
}

private extension PlaybackSkipZone {
    nonisolated func contains(_ position: TimeInterval) -> Bool {
        position >= startTime && position < endTime
    }
}
