import DeviceCheck
import Foundation
import OpenCastAnalysisProviders
import Testing
@testable import OpenCast

struct AppAttestInstallDeregistrationTests {
    @Test("An unregistered slot is untouched and sends nothing")
    func notRegistered() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        #expect(try await slot.deregistration().deregisterIfRegistered() == .notRegistered)
        #expect(slot.transport.requests.isEmpty)
        #expect(try slot.keychain.loadInstallID() == nil)
    }

    @Test("Delete sends the bound empty envelope while suspended and retires the right identifiers", arguments: [false, true])
    func deletesRegistered(keepsInstallID: Bool) async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        let installID = try slot.registerLocally()
        slot.suspension.suspend()
        #expect(try await slot.deregistration(keepsInstallID: keepsInstallID).deregisterIfRegistered() == .deregistered)
        #expect(slot.transport.requests.count == 1)
        let request = try #require(slot.transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/install/delete")
        let body = try #require(request.httpBody)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(envelope["install_id"] == installID)
        #expect(envelope["key_id"] == "old-key")
        #expect(envelope["payload"] == "{}")
        #expect(envelope["assertion"]?.isEmpty == false)
        #expect(try slot.keychain.loadAppAttestKeyID() == nil)
        #expect(try slot.keychain.loadInstallID() == (keepsInstallID ? installID : nil))
    }

    @Test("An unknown key retires locally without registering")
    func unknownKey() async throws {
        let slot = DeregistrationTestSlot(transport: .init(replies: [.unknownKey]))
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        #expect(try await slot.deregistration().deregisterIfRegistered() == .deregistered)
        #expect(try slot.keychain.loadInstallID() == nil)
        #expect(slot.transport.requests.map { $0.url?.path } == ["/v1/install/delete"])
    }

    @Test("Unconfirmed deletes retain their credentials", arguments: [500, 404, 410])
    func failedDelete(status: Int) async throws {
        let slot = DeregistrationTestSlot(transport: .init(replies: [.init(status: status, body: #"{"error":"unavailable"}"#)]))
        defer { try? slot.keychain.deleteAll() }
        let installID = try slot.registerLocally()
        await #expect(throws: AppAttestHTTPError.self) {
            try await slot.deregistration().deregisterIfRegistered()
        }
        #expect(try slot.keychain.loadInstallID() == installID)
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.map { $0.url?.path } == ["/v1/install/delete"])
    }

    @Test("Retirement requires both 401 and unknown_key", arguments: [
        DeregistrationTestTransport.Reply(status: 401, body: #"{"error":"invalid_assertion"}"#),
        DeregistrationTestTransport.Reply(status: 403, body: #"{"error":"unknown_key"}"#)
    ])
    func mismatchedRetirementError(reply: DeregistrationTestTransport.Reply) async throws {
        let slot = DeregistrationTestSlot(transport: .init(replies: [reply]))
        defer { try? slot.keychain.deleteAll() }
        let installID = try slot.registerLocally()
        await #expect(throws: AppAttestHTTPError.self) { try await slot.deregistration().deregisterIfRegistered() }
        #expect(try slot.keychain.loadInstallID() == installID)
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.map { $0.url?.path } == ["/v1/install/delete"])
    }

    @Test("A counter race retries only the delete")
    func counterRace() async throws {
        let slot = DeregistrationTestSlot(transport: .init(replies: [
            .init(status: 401, body: #"{"error":"invalid_counter"}"#), .deleted
        ]))
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        #expect(try await slot.deregistration().deregisterIfRegistered() == .deregistered)
        #expect(slot.transport.requests.map { $0.url?.path } == ["/v1/install/delete", "/v1/install/delete"])
    }

    @Test("Local assertion failure retains the key without attempting recovery")
    func assertionFailure() async throws {
        let slot = DeregistrationTestSlot(attest: .init(assertionError: NSError(
            domain: DCError.errorDomain, code: DCError.Code.invalidKey.rawValue
        )))
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        await #expect(throws: (any Error).self) { try await slot.deregistration().deregisterIfRegistered() }
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.isEmpty)
    }

    @Test("Late success and unknown_key replies cannot retire a cancelled slot", arguments: [false, true])
    func lateReply(unknownKey: Bool) async throws {
        let release = DeregistrationTestLatch()
        let slot = DeregistrationTestSlot(transport: .init(replies: [unknownKey ? .unknownKey : .deleted], release: release))
        defer { try? slot.keychain.deleteAll() }
        let installID = try slot.registerLocally()
        let unwound = DeregistrationTestLatch()
        await #expect(throws: AnalysisHTTPFailure.timeout) {
            try await TrialProxyDeadline.run(seconds: 0.05) {
                defer { unwound.release() }
                return try await slot.deregistration().deregisterIfRegistered()
            }
        }
        await slot.transport.entered.wait()
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        release.release()
        await unwound.wait()
        #expect(try slot.keychain.loadInstallID() == installID)
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.map { $0.url?.path } == ["/v1/install/delete"])
    }

    @Test("An assertion that outlives its deadline never reaches transport")
    func lateAssertion() async throws {
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let slot = DeregistrationTestSlot(attest: .init(assertionEntered: entered, assertionRelease: release))
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        let unwound = DeregistrationTestLatch()
        await #expect(throws: AnalysisHTTPFailure.timeout) {
            try await TrialProxyDeadline.run(seconds: 0.05) {
                defer { unwound.release() }
                return try await slot.deregistration().deregisterIfRegistered()
            }
        }
        await entered.wait()
        release.release()
        await unwound.wait()
        #expect(slot.transport.requests.isEmpty)
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
    }

    @Test("A delete timing out behind the gate keeps credentials and never sends later")
    func gateDeadline() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        let gate = AppAttestAssertionGate(suspension: slot.suspension)
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let holder = Task {
            try await gate.withSerializedSend(keyID: "old-key") {
                entered.release()
                await release.wait()
            }
        }
        await entered.wait()
        slot.suspension.suspend()
        let client = AppAttestInstallDeregistration(
            baseURL: slot.api.configuration.baseURL, keychainService: slot.keychain.service,
            transport: slot.transport, appAttestService: slot.attest, keepsInstallID: false,
            suspension: slot.suspension, assertionGate: gate
        )
        let unwound = DeregistrationTestLatch()
        await #expect(throws: AnalysisHTTPFailure.timeout) {
            try await TrialProxyDeadline.run(seconds: 0.05) {
                defer { unwound.release() }
                return try await client.deregisterIfRegistered()
            }
        }
        release.release()
        try await holder.value
        await unwound.wait()
        #expect(slot.transport.requests.isEmpty)
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
    }

    @Test("Old work surviving resume registers a new non-trial install")
    func recoveryAfterResume() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        let oldInstallID = try slot.registerLocally()
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let oldWork = Task {
            try await slot.credentials.withFreshCredentialOnRecoverableFailure { credential in
                if credential.keyID == "old-key" {
                    entered.release()
                    await release.wait()
                    throw AppAttestHTTPError(statusCode: 401, code: "unknown_key", detail: nil)
                }
                return credential
            }
        }
        await entered.wait()
        slot.suspension.suspend()
        #expect(try await slot.deregistration().deregisterIfRegistered() == .deregistered)
        slot.suspension.resume()
        release.release()
        let credential = try await oldWork.value
        #expect(credential.installID != oldInstallID)
        #expect(try slot.keychain.loadInstallID() == credential.installID)
        #expect(credential.keyID == "fresh-key")
        #expect(slot.transport.requests.map { $0.url?.path } == [
            "/v1/install/delete", "/v1/app-attest/challenge", "/v1/app-attest/register"
        ])
    }

    @Test("Deletion drains an in-flight registration and removes the newly saved key")
    func drainsRegistration() async throws {
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let slot = DeregistrationTestSlot(attest: .init(attestationEntered: entered, attestationRelease: release))
        defer { try? slot.keychain.deleteAll() }
        let registration = Task { try await slot.credentials.ensureRegisteredCredential() }
        await entered.wait()
        slot.suspension.suspend()
        let deletion = Task { try await slot.deregistration().deregisterIfRegistered() }
        #expect(slot.transport.requests.map { $0.url?.path } == ["/v1/app-attest/challenge"])
        release.release()
        _ = try await registration.value
        #expect(try await deletion.value == .deregistered)
        #expect(try slot.keychain.loadInstallID() == nil)
        let body = try #require(slot.transport.requests.last?.httpBody)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(envelope["key_id"] == "fresh-key")
    }
}

extension DeregistrationTestSlot {
    func deregistration(keepsInstallID: Bool = false) -> AppAttestInstallDeregistration {
        .init(
            baseURL: api.configuration.baseURL, keychainService: keychain.service,
            transport: transport, appAttestService: attest, keepsInstallID: keepsInstallID,
            suspension: suspension, assertionGate: .init(suspension: suspension)
        )
    }
}
