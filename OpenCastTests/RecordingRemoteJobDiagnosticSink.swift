import Foundation
@testable import OpenCast

/// Captures typed diagnostic events in order so a test can assert the
/// minimum trail an incident needs, without touching the file sink.
nonisolated final class RecordingRemoteJobDiagnosticSink: RemoteJobDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [RemoteJobDiagnosticEvent] = []

    var events: [RemoteJobDiagnosticEvent] {
        lock.withLock { storedEvents }
    }

    var kinds: [RemoteJobDiagnosticEvent.Kind] {
        events.map(\.kind)
    }

    func record(_ event: RemoteJobDiagnosticEvent) {
        lock.withLock { storedEvents.append(event) }
    }

    func events(of kind: RemoteJobDiagnosticEvent.Kind) -> [RemoteJobDiagnosticEvent] {
        events.filter { $0.kind == kind }
    }

    /// True when `sequence` appears in order (not necessarily adjacent)
    /// among the recorded kinds.
    func containsInOrder(_ sequence: [RemoteJobDiagnosticEvent.Kind]) -> Bool {
        var remaining = sequence[...]
        for kind in kinds {
            if kind == remaining.first {
                remaining = remaining.dropFirst()
            }
            if remaining.isEmpty {
                return true
            }
        }
        return remaining.isEmpty
    }
}
