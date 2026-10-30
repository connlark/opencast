import Foundation
import OpenCastAnalysisProviders
import Testing
@testable import OpenCast

struct AppAttestSuspensionTests {
    @Test("Suspension blocks normal sends, permits cleanup, and resume restores sending")
    func sendAdmission() async throws {
        let slot = DeregistrationTestSlot()
        slot.suspension.suspend()
        await #expect(throws: AppAttestSuspendedError.self) {
            _ = try await slot.secure.sendRawPayload(
                path: "/v1/secure/hello", installID: "install", keyID: "key", payload: "{}",
                response: AppAttestMessageResponse.self
            )
        }
        #expect(slot.transport.requests.isEmpty)
        _ = try await slot.secure.sendRawPayload(
            path: "/v1/install/delete", installID: "install", keyID: "key", payload: "{}",
            exemptFromSuspension: true, response: AppAttestMessageResponse.self
        )
        slot.suspension.resume()
        _ = try await slot.secure.sendRawPayload(
            path: "/v1/secure/hello", installID: "install", keyID: "key", payload: "{}",
            response: AppAttestMessageResponse.self
        )
        #expect(slot.transport.requests.count == 2)
    }

    @Test("Suspended registration never challenges or retries, and resume restores registration")
    func registrationAdmission() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        slot.suspension.suspend()
        await #expect(throws: AppAttestSuspendedError.self) {
            try await slot.credentials.withFreshCredentialOnRecoverableFailure { $0 }
        }
        #expect(slot.transport.requests.isEmpty)
        #expect(try slot.keychain.loadAppAttestKeyID() == nil)
        slot.suspension.resume()
        _ = try await slot.credentials.ensureRegisteredCredential()
        #expect(try slot.keychain.loadAppAttestKeyID() == "fresh-key")
        #expect(slot.transport.requests.map { $0.url?.path } == [
            "/v1/app-attest/challenge", "/v1/app-attest/register"
        ])
    }

    @Test("Recovery cannot discard a credential after suspension closes")
    func recoveryPreservesKey() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        await #expect(throws: AppAttestSuspendedError.self) {
            try await slot.credentials.withFreshCredentialOnRecoverableFailure { _ -> String in
                slot.suspension.suspend()
                throw AppAttestHTTPError(statusCode: 401, code: "unknown_key", detail: nil)
            }
        }
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.isEmpty)
    }

    @Test("An admitted registration saves its key before the slot drain completes")
    func drainInFlightRegistration() async throws {
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let slot = DeregistrationTestSlot(attest: .init(attestationEntered: entered, attestationRelease: release))
        defer { try? slot.keychain.deleteAll() }
        let registration = Task { try await slot.credentials.ensureRegisteredCredential() }
        await entered.wait()
        slot.suspension.suspend()
        #expect(slot.suspension.hasRegistrationSection(keychainService: slot.keychain.service))
        let drained = Task {
            await slot.suspension.drain(keychainService: slot.keychain.service)
            return try slot.keychain.loadAppAttestKeyID()
        }
        #expect(try slot.keychain.loadAppAttestKeyID() == nil)
        release.release()
        _ = try await registration.value
        #expect(try await drained.value == "fresh-key")
        #expect(!slot.suspension.hasRegistrationSection(keychainService: slot.keychain.service))
    }

    @Test("Recovery admitted before suspension can finish its nested registration")
    func nestedRegistration() async throws {
        let suspension = AppAttestSuspension()
        try await suspension.withRegistrationSection(keychainService: "slot") {
            suspension.suspend()
            try await suspension.withRegistrationSection(keychainService: "slot") { }
        }
        await suspension.drain(keychainService: "slot")
        #expect(!suspension.hasRegistrationSection(keychainService: "slot"))
    }
    @Test("Repeated drain deadlines remove cancelled waiters before registration ends")
    func cancelledDrainWaiters() async throws {
        let suspension = AppAttestSuspension()
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let section = Task {
            try await suspension.withRegistrationSection(keychainService: "slot") {
                entered.release()
                await release.wait()
            }
        }
        await entered.wait()
        defer { release.release() }
        for _ in 0..<2 {
            let returned = DeregistrationTestLatch()
            await #expect(throws: AnalysisHTTPFailure.timeout) {
                try await TrialProxyDeadline.run(seconds: 0.05) {
                    await suspension.drain(keychainService: "slot")
                    returned.release()
                }
            }
            // A second deadline makes a leaked continuation fail promptly.
            try await TrialProxyDeadline.run(seconds: 1) { await returned.wait() }
            #expect(suspension.drainWaiterCount(keychainService: "slot") == 0)
            #expect(suspension.hasRegistrationSection(keychainService: "slot"))
        }
        release.release()
        try await section.value
        #expect(suspension.drainWaiterCount(keychainService: "slot") == 0)
        await suspension.drain(keychainService: "slot")
    }

    @Test("An ordinary send queued before suspension is rejected at the head of the gate")
    func queuedSendIsRejected() async throws {
        let suspension = AppAttestSuspension()
        let gate = AppAttestAssertionGate(suspension: suspension)
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let holder = Task {
            try await gate.withSerializedSend(keyID: "key") {
                entered.release()
                await release.wait()
            }
        }
        await entered.wait()
        defer { release.release() }
        let queued = Task {
            try await gate.withSerializedSend(keyID: "key") {
                Issue.record("Suspended queued send reached its operation")
            }
        }
        try await TrialProxyDeadline.run(seconds: 1) {
            while await gate.enqueuedSendCount < 2 { try Task.checkCancellation(); await Task.yield() }
        }
        suspension.suspend()
        release.release()
        try await holder.value
        await #expect(throws: AppAttestSuspendedError.self) { try await queued.value }
    }

}
