import Foundation
import OpenCastAnalysisProviders
import Synchronization
import Testing
@testable import OpenCast

struct AnalysisServicesDeregistrationTests {
    @Test("Independent slots return success, failure and timeout without throwing")
    func mixedOutcomes() async throws {
        let release = DeregistrationTestLatch()
        let success = DeregistrationTestSlot()
        let failure = DeregistrationTestSlot(transport: .init(replies: [.init(status: 500, body: "{}")]))
        let hanging = DeregistrationTestSlot(transport: .init(release: release))
        defer {
            for slot in [success, failure, hanging] { try? slot.keychain.deleteAll() }
        }
        for slot in [success, failure, hanging] { _ = try slot.registerLocally() }
        let service = AnalysisServicesDeregistration(slots: [
            .adAnalysis: { _ in success.deregistration() },
            .transcriptAnalysis: { _ in failure.deregistration() },
            .trialProxy: { _ in hanging.deregistration() }
        ], timeoutSeconds: 0.1)
        let start = ContinuousClock.now
        let outcomes = await service.run()
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(outcomes.count == 3)
        guard case .deregistered? = outcomes[.adAnalysis],
              case .failed? = outcomes[.transcriptAnalysis],
              case .failed(let error)? = outcomes[.trialProxy] else {
            Issue.record("Missing per-slot outcomes")
            release.release()
            return
        }
        #expect(error as? AnalysisHTTPFailure == .timeout)
        #expect(try success.keychain.loadInstallID() == nil)
        #expect(try failure.keychain.loadAppAttestKeyID() == "old-key")
        #expect(try hanging.keychain.loadAppAttestKeyID() == "old-key")
        release.release()
    }

    @Test("Every failed slot is reported without throwing")
    func allFail() async throws {
        let slot = DeregistrationTestSlot(transport: .init(replies: [.init(status: 500, body: "{}")]))
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        let outcomes = await AnalysisServicesDeregistration(slots: [.remoteTranscription: { _ in slot.deregistration() }]).run()
        guard case .failed? = outcomes[.remoteTranscription] else { Issue.record("Expected failed slot"); return }
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
    }

    @Test("Resolution is inside the deadline and a late resolver cannot delete")
    func resolutionDeadline() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        let release = DeregistrationTestLatch()
        let resolved = DeregistrationTestLatch()
        let service = AnalysisServicesDeregistration(slots: [.trialProxy: { _ in
            await release.wait()
            resolved.release()
            return slot.deregistration()
        }], timeoutSeconds: 0.05)
        let outcomes = await service.run()
        guard case .failed(let error)? = outcomes[.trialProxy] else { Issue.record("Expected resolution timeout"); return }
        #expect(error as? AnalysisHTTPFailure == .timeout)
        release.release()
        await resolved.wait()
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.isEmpty)
    }

    @Test("A registration drain timeout reports busy and keeps the credential")
    func busyDrain() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        let entered = DeregistrationTestLatch()
        let release = DeregistrationTestLatch()
        let section = Task {
            try await slot.suspension.withRegistrationSection(keychainService: slot.keychain.service) {
                entered.release()
                await release.wait()
            }
        }
        await entered.wait()
        slot.suspension.suspend()
        let outcomes = await AnalysisServicesDeregistration(
            slots: [.trialProxy: { _ in slot.deregistration() }], timeoutSeconds: 0.05
        ).run()
        guard case .busy? = outcomes[.trialProxy] else { Issue.record("Expected busy drain"); release.release(); return }
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        release.release()
        try await section.value
        #expect(slot.transport.requests.isEmpty)
    }

    @Test("The StoreKit lookup is shared by concurrent slot resolvers")
    func sharesEnvironmentLookup() async {
        let calls = Mutex(0)
        let resolver: AnalysisServicesDeregistration.Resolver = { lookup in
            #expect((try? await lookup.environment()) == .production)
            return nil
        }
        let outcomes = await AnalysisServicesDeregistration(
            slots: Dictionary(uniqueKeysWithValues: AnalysisServicesDeregistration.Slot.allCases.map { ($0, resolver) }),
            storeEnvironment: { calls.withLock { $0 += 1 }; return .production }
        ).run()
        #expect(outcomes.count == 4)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Release production and sandbox factories use the registered deployment slots", arguments: [RemoteTranscriptionStoreEnvironment.production, .sandbox, .xcode])
    func releaseSlots(environment: RemoteTranscriptionStoreEnvironment) throws {
        let production = environment == .production
        let transcript = try #require(AnalysisServicesDeregistration.transcriptAnalysis(.release(for: environment)))
        let adConfiguration = try #require(AdAnalysisBackendConfiguration.release(for: environment))
        let ad = try #require(AnalysisServicesDeregistration.adAnalysis(adConfiguration))
        let remote = try #require(AnalysisServicesDeregistration.remoteTranscription(.release(for: environment)))
        let trialConfiguration = try #require(TrialProxyBackendConfiguration.release(
            for: environment, trialEndpoint: URL(string: "https://trial.opencast.mobile")!
        ))
        let trial = try #require(AnalysisServicesDeregistration.trialProxy(trialConfiguration))
        #expect(transcript.keychainService == (production ? TranscriptAnalysisAppAttestKeychainServices.production : TranscriptAnalysisAppAttestKeychainServices.prodStaging))
        #expect(ad.keychainService == (production ? AdAnalysisAppAttestKeychainServices.production : AdAnalysisAppAttestKeychainServices.prodStaging))
        #expect(remote.keychainService == (production ? RemoteTranscriptionAppAttestKeychainServices.production : RemoteTranscriptionAppAttestKeychainServices.prodStaging))
        #expect(trial.keychainService == (production ? TrialProxyAppAttestKeychainServices.production : TrialProxyAppAttestKeychainServices.prodStaging))
        #expect(trial.keepsInstallID)
        #expect(!transcript.keepsInstallID && !ad.keepsInstallID && !remote.keepsInstallID)
    }

    @Test("Unavailable configuration never reads or retires a credential")
    func unavailableSlots() async throws {
        let slot = DeregistrationTestSlot()
        defer { try? slot.keychain.deleteAll() }
        _ = try slot.registerLocally()
        let unavailable: AnalysisServicesDeregistration.Resolver = { _ in nil }
        let outcomes = await AnalysisServicesDeregistration(slots: Dictionary(uniqueKeysWithValues:
            AnalysisServicesDeregistration.Slot.allCases.map { ($0, unavailable) }
        )).run()
        #expect(outcomes.count == 4)
        for outcome in outcomes.values {
            guard case .configurationUnavailable = outcome else { Issue.record("Expected unavailable configuration"); continue }
        }
        #expect(try slot.keychain.loadAppAttestKeyID() == "old-key")
        #expect(slot.transport.requests.isEmpty)
        #expect(AdAnalysisBackendConfiguration.release(for: .unknown("test")) == nil)
        #expect(TrialProxyBackendConfiguration.release(for: .unknown("test"), trialEndpoint: URL(string: "https://trial.example")!) == nil)
        #if !DEBUG && !INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        #expect(await TranscriptAnalysisBackendConfiguration.resolve(storeEnvironment: { .unknown("test") }) == nil)
        #expect(await RemoteTranscriptionBackendConfiguration.resolve(storeEnvironment: { .unknown("test") }) == nil)
        #endif
    }

    @Test("Cached trial configuration survives a failing fresh environment provider")
    func cachedTrialConfiguration() async throws {
        let connection = AnalysisTrialConnection(storeEnvironment: { .production })
        let original = await connection.configuration(trialEndpoint: URL(string: "https://trial.example")!)
        let attempts = Mutex(0)
        let reused = await connection.configuration(
            trialEndpoint: URL(string: "https://changed.example")!,
            storeEnvironment: { attempts.withLock { $0 += 1 }; throw URLError(.notConnectedToInternet) }
        )
        #expect(original != nil)
        #expect(reused == original)
        #expect(attempts.withLock { $0 } == 0)
    }

    @Test("A cold trial lookup cancelled by deregistration remains retryable")
    func cancelledColdTrialConfiguration() async throws {
        let connection = AnalysisTrialConnection(routing: .storeEnvironment, storeEnvironment: { .production })
        let entered = DeregistrationTestLatch()
        let resolved = DeregistrationTestLatch()
        let endpoint = URL(string: "https://trial.example")!
        let outcomes = await AnalysisServicesDeregistration(slots: [.trialProxy: { lookup in
            defer { resolved.release() }
            let configuration = await connection.configuration(
                trialEndpoint: endpoint, storeEnvironment: { try await lookup.environment() }
            )
            #expect(configuration == nil)
            return nil
        }], storeEnvironment: {
            entered.release()
            try await Task.sleep(for: .seconds(60))
            return .production
        }, timeoutSeconds: 0.05).run()
        await entered.wait()
        try await TrialProxyDeadline.run(seconds: 1) { await resolved.wait() }
        guard case .failed? = outcomes[.trialProxy] else {
            Issue.record("Expected resolution deadline"); return
        }
        let healthy = await connection.configuration(trialEndpoint: endpoint)
        #expect(healthy == TrialProxyBackendConfiguration.release(for: .production, trialEndpoint: endpoint))
    }

    @Test("A cancelled resolution finishing first cannot poison a concurrent healthy resolution")
    func concurrentTrialResolution() async throws {
        let connection = AnalysisTrialConnection(routing: .storeEnvironment)
        let endpoint = URL(string: "https://trial.example")!
        let cancelledEntered = DeregistrationTestLatch()
        let healthyEntered = DeregistrationTestLatch()
        let healthyRelease = DeregistrationTestLatch()
        let cancelled = Task {
            await connection.configuration(trialEndpoint: endpoint, storeEnvironment: {
                cancelledEntered.release()
                try await Task.sleep(for: .seconds(60))
                return .sandbox
            })
        }
        await cancelledEntered.wait()
        let healthy = Task {
            await connection.configuration(trialEndpoint: endpoint, storeEnvironment: {
                healthyEntered.release()
                await healthyRelease.wait()
                return .production
            })
        }
        await healthyEntered.wait()
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        healthyRelease.release()
        let expected = TrialProxyBackendConfiguration.release(for: .production, trialEndpoint: endpoint)
        #expect(await healthy.value == expected)
        #expect(await connection.configuration(trialEndpoint: endpoint, storeEnvironment: { .sandbox }) == expected)
    }

    @Test("Unknown and failed trial resolution are not cached", arguments: [false, true])
    func unsuccessfulTrialResolution(throwsError: Bool) async {
        let connection = AnalysisTrialConnection(routing: .storeEnvironment)
        let endpoint = URL(string: "https://trial.example")!
        #expect(await connection.configuration(trialEndpoint: endpoint, storeEnvironment: {
            if throwsError { throw URLError(.notConnectedToInternet) }
            return .unknown("test")
        }) == nil)
        #expect(await connection.configuration(trialEndpoint: endpoint, storeEnvironment: { .production }) != nil)
    }

    @Test("Live resolver factories fail closed for an unknown StoreKit environment")
    func liveUnknownEnvironment() async throws {
        let transport = DeregistrationTestTransport()
        let services = [
            TranscriptAnalysisAppAttestKeychainServices.production,
            AdAnalysisAppAttestKeychainServices.production,
            RemoteTranscriptionAppAttestKeychainServices.production,
            TrialProxyAppAttestKeychainServices.production
        ]
        let keychains = services.map { AppAttestKeychain(service: $0) }
        // Restore any pre-existing simulator credentials after the test.
        let oldKeys = try keychains.map { try $0.loadAppAttestKeyID() }
        let oldInstalls = try keychains.map { try $0.loadInstallID() }
        defer {
            for (index, keychain) in keychains.enumerated() {
                if oldInstalls[index] == nil { try? keychain.deleteAll() }
                if let oldKey = oldKeys[index] { try? keychain.saveAppAttestKeyID(oldKey) }
                else { try? keychain.deleteAppAttestKeyID() }
            }
        }
        let installs = try keychains.map { keychain in
            let install = try keychain.loadOrCreateInstallID()
            try keychain.saveAppAttestKeyID("retained-key")
            return install
        }
        let calls = Mutex(0)
        let outcomes = await AnalysisServicesDeregistration.live(
            routing: .storeEnvironment,
            trialConnection: AnalysisTrialConnection(routing: .storeEnvironment),
            trialEndpoint: { URL(string: "https://trial.example")! },
            storeEnvironment: { calls.withLock { $0 += 1 }; return .unknown("test") },
            transport: transport
        ).run()
        #expect(calls.withLock { $0 } == 1)
        #expect(outcomes.count == 4)
        for outcome in outcomes.values {
            guard case .configurationUnavailable = outcome else {
                Issue.record("Expected unavailable configuration"); continue
            }
        }
        #expect(transport.requests.isEmpty)
        for (index, keychain) in keychains.enumerated() {
            #expect(try keychain.loadInstallID() == installs[index])
            #expect(try keychain.loadAppAttestKeyID() == "retained-key")
        }
    }

    @MainActor
    @Test("Current-build resolvers mirror the live clients, including the internal remote lane")
    func currentBuildResolvers() async throws {
        let transcript = await TranscriptAnalysisBackendConfiguration.resolve(storeEnvironment: { .unknown("test") })
        let ad = await AdAnalysisBackendConfiguration.resolve(storeEnvironment: { .unknown("test") })
        let remote = await RemoteTranscriptionBackendConfiguration.resolve(storeEnvironment: { .unknown("test") })
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        #expect(transcript?.workerBaseURL == TranscriptAnalysisBackendConfiguration.prodStaging.workerBaseURL)
        #expect(ad?.workerBaseURL == AdAnalysisBackendConfiguration.prodStaging.workerBaseURL)
        #elseif DEBUG
        #expect(transcript?.workerBaseURL == TranscriptAnalysisBackendConfiguration.current.workerBaseURL)
        #expect(ad?.workerBaseURL == AdAnalysisBackendConfiguration.current.workerBaseURL)
        #else
        #expect(transcript == nil)
        #expect(ad == nil)
        #endif
        #if DEBUG
        #expect(remote?.workerBaseURL == RemoteTranscriptionBackendConfiguration.current.workerBaseURL)
        #else
        #expect(remote == nil)
        #endif
    }

    #if DEBUG
    @Test("Bearer configurations are skipped; a disabled attested slot can still be deleted")
    func bearerAndDisabled() {
        let environment = [
            "OPENCAST_TRANSCRIPT_ANALYSIS_CLIENT_TOKEN": "test", "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN": "test",
            "OPENCAST_REMOTE_TRANSCRIPTION_CLIENT_TOKEN": "test", "OPENCAST_TRIAL_PROXY_CLIENT_TOKEN": "test"
        ]
        #expect(AnalysisServicesDeregistration.transcriptAnalysis(.debug(environment: environment)) == nil)
        #expect(AnalysisServicesDeregistration.adAnalysis(.debug(environment: environment)) == nil)
        #expect(AnalysisServicesDeregistration.remoteTranscription(.debug(environment: environment)) == nil)
        #expect(AnalysisServicesDeregistration.trialProxy(.debug(environment: environment)) == nil)
        #expect(AnalysisServicesDeregistration.transcriptAnalysis(.disabled) != nil)
        #expect(AnalysisServicesDeregistration.remoteTranscription(.disabled) != nil)
    }
    #endif
}
