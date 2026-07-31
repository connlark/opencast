import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Foreground maintenance gate")
struct ForegroundMaintenanceGateTests {
    @Test("First activation after launch runs the full pass")
    func firstActivationRunsFullPass() {
        let gate = ForegroundMaintenanceGate()

        #expect(gate.shouldRunMaintenancePass(now: .now))
    }

    @Test("Re-activation with no remote change inside the ceiling skips the pass")
    func quietReactivationInsideCeilingSkips() {
        var gate = ForegroundMaintenanceGate()
        let completedAt = Date.now

        gate.recordCompletedPass(at: completedAt)

        #expect(!gate.shouldRunMaintenancePass(now: completedAt.addingTimeInterval(60)))
    }

    @Test("Re-activation after a non-self remote change runs the full pass")
    func remoteChangeForcesFullPass() {
        var gate = ForegroundMaintenanceGate()
        let completedAt = Date.now

        gate.recordCompletedPass(at: completedAt)
        gate.recordRemoteChange()

        #expect(gate.shouldRunMaintenancePass(now: completedAt.addingTimeInterval(60)))
    }

    @Test("The staleness ceiling forces a pass without any signal")
    func stalenessCeilingForcesPass() {
        var gate = ForegroundMaintenanceGate()
        let completedAt = Date.now

        gate.recordCompletedPass(at: completedAt)

        #expect(gate.shouldRunMaintenancePass(
            now: completedAt.addingTimeInterval(ForegroundMaintenanceGate.stalenessCeiling)
        ))
        #expect(!gate.shouldRunMaintenancePass(
            now: completedAt.addingTimeInterval(ForegroundMaintenanceGate.stalenessCeiling - 1)
        ))
    }

    @Test("A completed pass consumes the remote-change signal")
    func completedPassConsumesRemoteChangeSignal() {
        var gate = ForegroundMaintenanceGate()
        let completedAt = Date.now

        gate.recordCompletedPass(at: completedAt)
        gate.recordRemoteChange()
        gate.recordCompletedPass(at: completedAt.addingTimeInterval(120))

        #expect(!gate.shouldRunMaintenancePass(now: completedAt.addingTimeInterval(180)))
    }
}
