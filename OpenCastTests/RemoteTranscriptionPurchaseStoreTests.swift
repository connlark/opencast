import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

/// StoreKit outcome matrix for the purchase store via the injectable seams:
/// pending/cancelled/unverified/verified purchases, finish-only-after-ack,
/// launch reconciliation, duplicate-redeem idempotency, catalog-mismatch
/// fail-closed, gating, and the consumption preview's overdraft arithmetic.
@MainActor
struct RemoteTranscriptionPurchaseStoreTests {
    private static let hours20 = "com.connor.opencast.transcription.hours20.v1"
    private static let hours100 = "com.connor.opencast.transcription.hours100.v1"

    @Test("Available: verified purchase redeems, then finishes, then updates balance")
    func verifiedPurchaseFinishesAfterAck() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .success(Self.transaction(id: 7))
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        #expect(store.availability == .available)
        #expect(store.balance?.availableSeconds == 3600)

        await store.purchase(store.products[0])
        #expect(api.redeemedJWS == ["jws-7"])
        #expect(storeKit.finishedIDs == [7])
        #expect(store.purchasePhase == .completed(creditedSeconds: 72_000))
        #expect(store.balance?.availableSeconds == 75_600)
    }

    @Test("Failed redeem leaves the transaction unfinished for later retry")
    func failedRedeemNeverFinishes() async {
        let api = FakePurchaseAPI()
        api.redeemError = RemoteTranscriptionHTTPError(statusCode: 503, code: "internal_error", detail: nil)
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .success(Self.transaction(id: 9))
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.purchase(store.products[0])
        #expect(storeKit.finishedIDs.isEmpty)
        if case .failed = store.purchasePhase {} else {
            Issue.record("expected failed phase, got \(store.purchasePhase)")
        }
    }

    @Test("Unknown redeem outcome fails closed: no finish")
    func unknownOutcomeNeverFinishes() async {
        let api = FakePurchaseAPI()
        api.redeemOutcome = .unknown("mystery")
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .success(Self.transaction(id: 4))
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.purchase(store.products[0])
        #expect(storeKit.finishedIDs.isEmpty)
    }

    @Test("Pending, cancelled, and unverified purchases never touch the server")
    func nonSuccessOutcomes() async {
        for (result, expectFailure) in [
            (RemoteTranscriptionStorePurchaseResult.pending, false),
            (.cancelled, false),
            (.unverified, true),
        ] {
            let api = FakePurchaseAPI()
            let storeKit = FakeStoreKitClient()
            storeKit.purchaseResult = result
            let store = Self.makeStore(api: api, storeKit: storeKit)
            await store.prepare()
            await store.purchase(store.products[0])
            #expect(api.redeemedJWS.isEmpty)
            #expect(storeKit.finishedIDs.isEmpty)
            switch (result, store.purchasePhase) {
            case (.pending, .pendingApproval), (.cancelled, .idle):
                break
            case (.unverified, .failed):
                break
            default:
                Issue.record("unexpected phase \(store.purchasePhase) for \(result); failureExpected=\(expectFailure)")
            }
        }
    }

    @Test("Launch reconciliation redeems unfinished transactions exactly once")
    func launchReconciliation() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.unfinished = [Self.transaction(id: 11), Self.transaction(id: 12)]
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        #expect(api.redeemedJWS.sorted() == ["jws-11", "jws-12"])
        #expect(storeKit.finishedIDs.sorted() == [11, 12])

        // A second prepare() is idempotent: nothing re-redeems.
        await store.prepare()
        #expect(api.redeemedJWS.count == 2)
    }

    @Test("Refresh Purchases syncs then sweeps full history without double-crediting")
    func refreshPurchasesSweep() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.all = [Self.transaction(id: 21)]
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.refreshPurchases()
        #expect(storeKit.syncCalls == 1)
        #expect(api.redeemedJWS == ["jws-21"])

        // Sweeping again within the session is a no-op for the same id.
        await store.refreshPurchases()
        #expect(api.redeemedJWS.count == 1)
    }

    @Test("A successful purchase is immediately refundable even when transaction history lags")
    func successfulPurchaseImmediatelyBecomesRefundable() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        let oldPurchaseDate = Date(timeIntervalSince1970: 1_000)
        let newPurchaseDate = Date(timeIntervalSince1970: 2_000)
        let oldTransaction = Self.transaction(id: 41, purchaseDate: oldPurchaseDate)
        let newTransaction = Self.transaction(id: 42, purchaseDate: newPurchaseDate)
        storeKit.all = [oldTransaction]
        storeKit.purchaseResult = .success(newTransaction)
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.refreshRefundCandidates()
        #expect(store.refundCandidates.map(\.id) == [41])

        await store.purchase(store.products[0])
        #expect(store.refundCandidates.map(\.id) == [42, 41])

        // Transaction.all can return the snapshot it began loading before
        // the purchase. Merging must not erase the just-purchased transaction.
        await store.refreshRefundCandidates()
        #expect(store.refundCandidates.map(\.id) == [42, 41])
    }

    @Test("Refund candidates exclude ineligible transactions and stay hidden after a request")
    func refundCandidateEligibilityAndSessionHiding() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        let purchaseDate = Date(timeIntervalSince1970: 3_000)
        storeKit.all = [
            Self.transaction(id: 51, purchaseDate: purchaseDate),
            Self.transaction(id: 52, purchaseDate: purchaseDate, isVerified: false),
            Self.transaction(
                id: 53,
                purchaseDate: purchaseDate,
                revocationDate: purchaseDate.addingTimeInterval(1)
            ),
            Self.transaction(
                id: 54,
                productID: "com.connor.opencast.unrelated",
                purchaseDate: purchaseDate
            ),
        ]
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.refreshRefundCandidates()
        #expect(store.refundCandidates.map(\.id) == [51])

        store.markRefundRequested(transactionID: 51)
        await store.refreshRefundCandidates()
        #expect(store.refundCandidates.isEmpty)
    }

    @Test("Catalog mismatch fails closed: store disabled, no products")
    func catalogMismatchFailsClosed() async {
        let api = FakePurchaseAPI()
        api.catalogSHA256 = "not-the-real-hash"
        let storeKit = FakeStoreKitClient()
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        if case .storeDisabled = store.availability {} else {
            Issue.record("expected storeDisabled, got \(store.availability)")
        }
        #expect(store.products.isEmpty)
        // Balance surfaces still work — money display is untouched.
        #expect(store.balance?.availableSeconds == 3600)
    }

    @Test("Kill switch (purchases_enabled=false) disables the store, keeps balance")
    func killSwitchDisablesStore() async {
        let api = FakePurchaseAPI()
        api.purchasesEnabled = false
        let storeKit = FakeStoreKitClient()
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        if case .storeDisabled = store.availability {} else {
            Issue.record("expected storeDisabled, got \(store.availability)")
        }
        #expect(store.balance != nil)
    }

    @Test("Production lane accepts a production StoreKit environment")
    func productionEnvironmentUsesStore() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.environmentValue = .production
        let store = RemoteTranscriptionPurchaseStore(
            api: api,
            storeKit: storeKit,
            configuration: .production
        )

        await store.prepare()
        #expect(store.availability == .available)
        #expect(api.bootstrapCalls == 1)
    }

    @Test("Fixed configuration bypasses StoreKit environment resolution")
    func fixedConfigurationBypassesEnvironmentResolution() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()

        #expect(storeKit.environmentCalls == 0)
        #expect(store.availability == .available)
    }

    #if DEBUG
    @Test("DEBUG configuration bypasses StoreKit environment resolution")
    func debugConfigurationBypassesEnvironmentResolution() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        let store = RemoteTranscriptionPurchaseStore(api: api, storeKit: storeKit)

        await store.prepare()

        #expect(storeKit.environmentCalls == 0)
        #expect(api.bootstrapCalls == 1)
        if case .storeDisabled = store.availability {} else {
            Issue.record("expected storeDisabled, got \(store.availability)")
        }
    }

    @Test("App Review fixture keeps every async entry point I/O-free")
    func reviewFixtureIsIOFree() async {
        let api = FakePurchaseAPI()
        api.balance = OpenCastRemoteTranscriptionBalance(
            availableSeconds: 99,
            reservedSeconds: 98,
            debtSeconds: 97
        )
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .success(Self.transaction(id: 31))
        let store = Self.makeStore(api: api, storeKit: storeKit)
        store.applyReviewScreenshotFixture()
        let fixtureProducts = store.products
        let fixtureBalance = store.balance

        await store.prepare()
        await store.purchase(store.products[0])
        await store.refreshPurchases()
        await store.refreshBalance()
        await store.refreshRefundCandidates()

        #expect(api.bootstrapCalls == 0)
        #expect(api.redeemCalls == 0)
        #expect(storeKit.environmentCalls == 0)
        #expect(storeKit.productCalls == 0)
        #expect(storeKit.purchaseCalls == 0)
        #expect(storeKit.syncCalls == 0)
        #expect(storeKit.finishedIDs.isEmpty)
        #expect(storeKit.unfinishedTransactionCalls == 0)
        #expect(storeKit.allTransactionCalls == 0)
        #expect(storeKit.transactionUpdatesCalls == 0)
        #expect(store.products == fixtureProducts)
        #expect(store.balance == fixtureBalance)
        #expect(store.purchasePhase == .idle)
    }

    @Test("Refresh Purchases clears a terminal phase")
    func refreshPurchasesClearsTerminalPhase() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .unverified
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.purchase(store.products[0])
        guard case .failed = store.purchasePhase else {
            Issue.record("expected failed phase, got \(store.purchasePhase)")
            return
        }

        await store.refreshPurchases()

        #expect(store.purchasePhase == .idle)
    }

    @Test("dismissPurchasePhase clears terminal rows but leaves pending approval")
    func dismissPurchasePhaseClearsTerminalOnly() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .pending
        let store = Self.makeStore(api: api, storeKit: storeKit)

        await store.prepare()
        await store.purchase(store.products[0])
        #expect(store.purchasePhase == .pendingApproval)

        store.dismissPurchasePhase()
        #expect(store.purchasePhase == .pendingApproval)

        storeKit.purchaseResult = .success(Self.transaction(id: 41))
        await store.purchase(store.products[0])
        #expect(store.purchasePhase == .completed(creditedSeconds: 72_000))

        store.dismissPurchasePhase()
        #expect(store.purchasePhase == .idle)
    }

    @Test("App Review fixture derives ordered identity and grants from the embedded catalog")
    func reviewFixtureMatchesEmbeddedCatalog() {
        let store = Self.makeStore(api: FakePurchaseAPI(), storeKit: FakeStoreKitClient())
        store.applyReviewScreenshotFixture()

        #expect(store.products.count == RemoteTranscriptionEmbeddedCatalog.products.count)
        for (product, catalogProduct) in zip(
            store.products,
            RemoteTranscriptionEmbeddedCatalog.products
        ) {
            #expect(product.id == catalogProduct.productID)
            #expect(product.grantSeconds == catalogProduct.grantSeconds)
        }
        #expect(store.products.map(\.displayName) == [
            "20 Transcription Hours",
            "100 Transcription Hours",
        ])
        #expect(store.products.map(\.displayPrice) == ["$0.99", "$4.99"])
    }
    #endif

    @Test("Launch environment lookup remains bounded")
    func launchEnvironmentLookupIsBounded() async {
        let storeKit = FakeStoreKitClient()
        storeKit.environmentValue = .production
        // Parked far beyond any load stall: the 30 ms timeout must win this
        // race deterministically (a 500 ms delay lost it once under full-suite
        // load, 2026-07-29).
        storeKit.environmentDelay = .seconds(3600)

        let environment = await RemoteTranscriptionPurchaseStore.resolvedEnvironment(
            storeKit: storeKit,
            timeout: .milliseconds(30)
        )

        #expect(environment == .unknown("unavailable"))
        #expect(storeKit.environmentCalls == 1)
        #expect(!storeKit.environmentDidComplete)
    }

    @Test("Explicit refresh can outlast launch timeout and routes Sandbox to prod-staging")
    func refreshOutlastsLaunchTimeout() async {
        let storeKit = FakeStoreKitClient()
        storeKit.environmentValue = .sandbox
        storeKit.environmentDelay = .milliseconds(120)

        let environment = await RemoteTranscriptionPurchaseStore.resolvedEnvironment(
            storeKit: storeKit,
            refresh: true,
            timeout: .milliseconds(30)
        )
        let configuration = RemoteTranscriptionBackendConfiguration.release(for: environment)

        #expect(environment == .sandbox)
        #expect(storeKit.environmentCalls == 0)
        #expect(storeKit.refreshEnvironmentCalls == 1)
        #expect(storeKit.environmentDidComplete)
        #expect(configuration.workerBaseURL == RemoteTranscriptionBackendConfiguration.prodStagingWorkerBaseURL)
        #expect(configuration.isEnabled)
    }

    @Test("Environment lookup returns a successful result")
    func environmentLookupSucceeds() async {
        let storeKit = FakeStoreKitClient()
        storeKit.environmentValue = .production

        let environment = await RemoteTranscriptionPurchaseStore.resolvedEnvironment(
            storeKit: storeKit,
            timeout: .milliseconds(100)
        )

        #expect(environment == .production)
        #expect(storeKit.environmentCalls == 1)
        #expect(storeKit.environmentDidComplete)
    }

    @Test("Environment lookup error fails closed")
    func environmentLookupErrorFailsClosed() async {
        let storeKit = FakeStoreKitClient()
        storeKit.environmentError = URLError(.cannotConnectToHost)

        let environment = await RemoteTranscriptionPurchaseStore.resolvedEnvironment(
            storeKit: storeKit,
            timeout: .milliseconds(100)
        )

        #expect(environment == .unknown("unavailable"))
        #expect(storeKit.environmentCalls == 1)
        #expect(storeKit.environmentDidComplete)
    }

    @Test("Failed environment resolution stays visible and explicit refresh can recover")
    func failedEnvironmentResolutionCanRetry() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.environmentError = URLError(.notConnectedToInternet)
        let store = RemoteTranscriptionPurchaseStore(
            api: api,
            storeKit: storeKit,
            configurationResolver: { refresh in
                let environment = await RemoteTranscriptionPurchaseStore.resolvedEnvironment(
                    storeKit: storeKit,
                    refresh: refresh,
                    timeout: .milliseconds(30)
                )
                return .release(for: environment)
            }
        )

        await store.prepare()

        if case .unavailable(let reason) = store.availability {
            #expect(reason.contains("App Store"))
        } else {
            Issue.record("expected unavailable, got \(store.availability)")
        }
        #expect(!store.isSurfaceVisible)
        #expect(storeKit.environmentCalls == 1)
        #expect(storeKit.refreshEnvironmentCalls == 0)
        #expect(api.bootstrapCalls == 0)

        storeKit.environmentError = nil
        storeKit.environmentValue = .sandbox
        storeKit.environmentDelay = .milliseconds(100)
        await store.retryPreparation()

        #expect(storeKit.environmentCalls == 1)
        #expect(storeKit.refreshEnvironmentCalls == 1)
        #expect(store.availability == .available)
        #expect(store.isSurfaceVisible)
        #expect(api.bootstrapCalls == 1)
    }

    @Test("A cancelled waiter does not cancel the shared preparation")
    func cancelledWaiterKeepsSharedPreparationAlive() async throws {
        let api = FakePurchaseAPI()
        api.bootstrapDelay = .milliseconds(150)
        let store = Self.makeStore(api: api, storeKit: FakeStoreKitClient())

        // The launch caller starts preparation and parks on the slow
        // bootstrap; a transient surface then joins mid-flight and its .task
        // is cancelled (sheet dismissed, card scrolled away).
        let launchPrepare = Task { await store.prepare() }
        for _ in 0..<200 where api.bootstrapCalls == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(api.bootstrapCalls == 1)
        let transientWaiter = Task { await store.prepare() }
        try await Task.sleep(for: .milliseconds(10))
        transientWaiter.cancel()
        await transientWaiter.value
        await launchPrepare.value

        // The launch preparation must survive the waiter's cancellation and
        // resolve availability; a cancelled shared task would strand it at
        // .unknown and hide every purchase surface for the session.
        #expect(store.availability == .available)
        #expect(store.isSurfaceVisible)
    }

    @Test("Cancelled AppTransaction lookup is evicted and immediately retryable")
    func cancelledAppTransactionLookupCanRetry() async throws {
        let source = FakeAppTransactionSnapshotSource(
            currentDelayOnFirstCall: .seconds(5)
        )
        let cache = RemoteTranscriptionAppTransactionCache(
            currentSnapshotLoader: { try await source.currentSnapshot() },
            refreshedSnapshotLoader: { try await source.refreshedSnapshot() }
        )
        let firstLookup = Task { try await cache.snapshot() }

        for _ in 0..<100 where source.currentCalls == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.currentCalls == 1)

        firstLookup.cancel()
        do {
            _ = try await firstLookup.value
            Issue.record("Expected the first cache lookup to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let retriedSnapshot = try await cache.snapshot()
        #expect(retriedSnapshot.jwsRepresentation == "current-jws")
        #expect(retriedSnapshot.environment == .production)
        #expect(source.currentCalls == 2)
    }

    @Test("Failure is retryable and refreshed snapshot drives routed bootstrap")
    func refreshedSnapshotReplacesFailedLookupForRouting() async throws {
        let source = FakeAppTransactionSnapshotSource(
            refreshedSnapshot: RemoteTranscriptionAppTransactionSnapshot(
                jwsRepresentation: "refreshed-jws",
                environment: .sandbox
            ),
            failingCurrentCalls: [1]
        )
        let cache = RemoteTranscriptionAppTransactionCache(
            currentSnapshotLoader: { try await source.currentSnapshot() },
            refreshedSnapshotLoader: { try await source.refreshedSnapshot() }
        )

        do {
            _ = try await cache.snapshot()
            Issue.record("Expected the first cache lookup to fail")
        } catch {
            #expect(source.currentCalls == 1)
        }

        let retriedSnapshot = try await cache.snapshot()
        #expect(retriedSnapshot.environment == .production)
        #expect(source.currentCalls == 2)

        let refreshedSnapshot = try await cache.refreshedSnapshot()
        #expect(refreshedSnapshot.environment == .sandbox)
        #expect(refreshedSnapshot.jwsRepresentation == "refreshed-jws")

        let api = FakePurchaseAPI()
        let configurationRecorder = FakeRemoteTranscriptionConfigurationRecorder()
        let routedAPI = RemoteTranscriptionRoutedAPIClient(
            environmentProvider: { try await cache.snapshot().environment },
            clientFactory: { configuration in
                configurationRecorder.record(configuration)
                return api
            }
        )

        _ = try await routedAPI.bootstrap()
        let reusedSnapshot = try await cache.snapshot()
        let routedConfigurations = configurationRecorder.configurations
        #expect(reusedSnapshot.jwsRepresentation == "refreshed-jws")
        #expect(source.currentCalls == 2)
        #expect(source.refreshCalls == 1)
        #expect(api.bootstrapCalls == 1)
        #expect(routedConfigurations.count == 1)
        #expect(
            routedConfigurations.first?.workerBaseURL
                == RemoteTranscriptionBackendConfiguration.prodStagingWorkerBaseURL
        )
    }

    @Test("Consumption preview mirrors the server's overdraft arithmetic")
    func consumptionPreview() async {
        let api = FakePurchaseAPI()
        api.balance = OpenCastRemoteTranscriptionBalance(
            availableSeconds: 3600,
            reservedSeconds: 0,
            debtSeconds: 0
        )
        let storeKit = FakeStoreKitClient()
        let store = Self.makeStore(api: api, storeKit: storeKit)
        await store.prepare()

        let covered = store.estimate(durationSeconds: 1800)
        #expect(covered.overdraftSeconds == 0)
        #expect(covered.fitsWithinHeadroom)

        let overdraft = store.estimate(durationSeconds: 4000)
        #expect(overdraft.overdraftSeconds == 400)
        #expect(overdraft.fitsWithinHeadroom)

        let blocked = store.estimate(durationSeconds: 15_000)
        #expect(!blocked.fitsWithinHeadroom)
    }

    @Test("Analysis preview bridges units: the flat rate scales the charge against the same balance")
    func analysisEstimateBridgesUnits() async {
        let api = FakePurchaseAPI()
        api.balance = OpenCastRemoteTranscriptionBalance(
            availableSeconds: 3600,
            reservedSeconds: 0,
            debtSeconds: 0
        )
        let storeKit = FakeStoreKitClient()
        let store = Self.makeStore(api: api, storeKit: storeKit)
        await store.prepare()

        // One analyzed audio-hour charges the full flat rate (7,850 s),
        // which overdrafts a fresh 3,600 s grant but fits inside the debt
        // headroom — the H7 worked example.
        let hour = store.analysisEstimate(durationSeconds: 3600)
        #expect(hour?.estimatedSeconds == 7850)
        #expect(hour?.overdraftSeconds == 4250)
        #expect(hour?.fitsWithinHeadroom == true)

        // A 3.454 h episode outprices new-account headroom entirely (H7).
        let long = store.analysisEstimate(durationSeconds: 12_434.5)
        #expect(long?.estimatedSeconds == 27_115)
        #expect(long?.fitsWithinHeadroom == false)

        #expect(store.analysisEstimate(durationSeconds: 0) == nil)
        #expect(store.analysisEstimate(durationSeconds: -30) == nil)
    }

    @Test("Balance-increase callback fires only when a redeem actually credits")
    func balanceIncreaseCallbackFiresOnlyOnCredit() async {
        let api = FakePurchaseAPI()
        let storeKit = FakeStoreKitClient()
        storeKit.purchaseResult = .success(Self.transaction(id: 21))
        let store = Self.makeStore(api: api, storeKit: storeKit)
        var balanceIncreaseCount = 0
        store.onBalanceIncreased = { balanceIncreaseCount += 1 }

        await store.prepare()
        await store.purchase(store.products[0])
        #expect(balanceIncreaseCount == 1)

        // An already-credited replay moves no money and must not re-probe
        // balance-deferred work, even though the server echoes the original
        // positive creditedSeconds.
        api.redeemOutcome = .alreadyCredited
        storeKit.purchaseResult = .success(Self.transaction(id: 22))
        await store.purchase(store.products[0])
        #expect(balanceIncreaseCount == 1)

        // A refund acknowledgement also echoes the original grant while the
        // balance went DOWN — it must not fire either.
        api.redeemOutcome = .refunded
        storeKit.purchaseResult = .success(Self.transaction(id: 23))
        await store.purchase(store.products[0])
        #expect(balanceIncreaseCount == 1)
    }

    // MARK: - Fixtures

    private static func makeStore(
        api: FakePurchaseAPI,
        storeKit: FakeStoreKitClient
    ) -> RemoteTranscriptionPurchaseStore {
        RemoteTranscriptionPurchaseStore(
            api: api,
            storeKit: storeKit,
            configuration: RemoteTranscriptionBackendConfiguration.prodStaging
        )
    }

    private static func transaction(
        id: UInt64,
        productID: String = hours20,
        purchaseDate: Date? = nil,
        revocationDate: Date? = nil,
        isVerified: Bool = true
    ) -> RemoteTranscriptionStoreTransaction {
        RemoteTranscriptionStoreTransaction(
            id: id,
            productID: productID,
            jwsRepresentation: "jws-\(id)",
            purchaseDate: purchaseDate,
            revocationDate: revocationDate,
            isVerified: isVerified
        )
    }
}

// MARK: - Fakes

private final class FakePurchaseAPI: RemoteTranscriptionAPI, @unchecked Sendable {
    private let lock = NSLock()

    var balance = OpenCastRemoteTranscriptionBalance(availableSeconds: 3600, reservedSeconds: 0, debtSeconds: 0)
    var catalogSHA256 = RemoteTranscriptionEmbeddedCatalog.catalogSHA256
    var purchasesEnabled = true
    var redeemError: Error?
    var redeemOutcome: OpenCastRemoteTranscriptionRedeemOutcome = .credited
    var bootstrapDelay: Duration?

    private var recordedBootstrapCalls = 0
    private var recordedRedeemCalls = 0
    private var recordedRedeemedJWS: [String] = []

    var bootstrapCalls: Int {
        lock.withLock { recordedBootstrapCalls }
    }

    var redeemCalls: Int {
        lock.withLock { recordedRedeemCalls }
    }

    var redeemedJWS: [String] {
        lock.withLock { recordedRedeemedJWS }
    }

    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        lock.withLock { recordedBootstrapCalls += 1 }
        if let bootstrapDelay {
            try await Task.sleep(for: bootstrapDelay)
        }
        return OpenCastRemoteTranscriptionBootstrapResponse(
            schemaVersion: 1,
            accountID: "pacct-fake",
            balance: balance,
            appAccountToken: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            catalog: RemoteTranscriptionEmbeddedCatalog.products,
            catalogSHA256: catalogSHA256,
            purchasesEnabled: purchasesEnabled
        )
    }

    func redeem(
        transactionJWS: String
    ) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        lock.withLock { recordedRedeemCalls += 1 }
        if let redeemError {
            throw redeemError
        }
        // Like the real PurchaseWorker: every acknowledgement echoes the
        // original positive grant, but only `credited` moves the balance.
        let credited = Int64(72_000)
        lock.withLock {
            recordedRedeemedJWS.append(transactionJWS)
            if redeemOutcome == .credited {
                balance = OpenCastRemoteTranscriptionBalance(
                    availableSeconds: balance.availableSeconds + credited,
                    reservedSeconds: balance.reservedSeconds,
                    debtSeconds: balance.debtSeconds
                )
            }
        }
        return OpenCastRemoteTranscriptionRedeemResponse(
            schemaVersion: 1,
            outcome: redeemOutcome,
            transactionID: transactionJWS,
            creditedSeconds: credited,
            balance: balance
        )
    }

    // Unused by the purchase store.
    func createJob(_ request: OpenCastRemoteTranscriptionJobCreateRequest) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func reportSource(jobID: String, identity: OpenCastRemoteTranscriptionSourceIdentity) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func ack(jobID: String, normalizedTranscriptSHA256: String?) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }
}

private final class FakeAppTransactionSnapshotSource: @unchecked Sendable {
    private let lock = NSLock()

    private let currentSnapshotValue: RemoteTranscriptionAppTransactionSnapshot
    private let refreshedSnapshotValue: RemoteTranscriptionAppTransactionSnapshot
    private let currentDelayOnFirstCall: Duration?
    private let failingCurrentCalls: Set<Int>

    private var recordedCurrentCalls = 0
    private var recordedRefreshCalls = 0

    init(
        currentSnapshot: RemoteTranscriptionAppTransactionSnapshot = RemoteTranscriptionAppTransactionSnapshot(
            jwsRepresentation: "current-jws",
            environment: .production
        ),
        refreshedSnapshot: RemoteTranscriptionAppTransactionSnapshot = RemoteTranscriptionAppTransactionSnapshot(
            jwsRepresentation: "refreshed-jws",
            environment: .production
        ),
        currentDelayOnFirstCall: Duration? = nil,
        failingCurrentCalls: Set<Int> = []
    ) {
        currentSnapshotValue = currentSnapshot
        refreshedSnapshotValue = refreshedSnapshot
        self.currentDelayOnFirstCall = currentDelayOnFirstCall
        self.failingCurrentCalls = failingCurrentCalls
    }

    var currentCalls: Int {
        lock.withLock { recordedCurrentCalls }
    }

    var refreshCalls: Int {
        lock.withLock { recordedRefreshCalls }
    }

    func currentSnapshot() async throws -> RemoteTranscriptionAppTransactionSnapshot {
        let (call, delay, shouldFail) = lock.withLock {
            recordedCurrentCalls += 1
            return (
                recordedCurrentCalls,
                currentDelayOnFirstCall,
                failingCurrentCalls.contains(recordedCurrentCalls)
            )
        }
        if call == 1, let delay {
            try await Task.sleep(for: delay)
        }
        if shouldFail {
            throw URLError(.cannotConnectToHost)
        }
        return currentSnapshotValue
    }

    func refreshedSnapshot() async throws -> RemoteTranscriptionAppTransactionSnapshot {
        lock.withLock { recordedRefreshCalls += 1 }
        return refreshedSnapshotValue
    }
}

nonisolated private final class FakeRemoteTranscriptionConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedConfigurations: [RemoteTranscriptionBackendConfiguration] = []

    var configurations: [RemoteTranscriptionBackendConfiguration] {
        lock.withLock { recordedConfigurations }
    }

    func record(_ configuration: RemoteTranscriptionBackendConfiguration) {
        lock.withLock { recordedConfigurations.append(configuration) }
    }
}

private final class FakeStoreKitClient: RemoteTranscriptionStoreKitClient, @unchecked Sendable {
    private let lock = NSLock()

    var environmentValue: RemoteTranscriptionStoreEnvironment = .sandbox
    var environmentDelay: Duration?
    var environmentError: Error?
    var purchaseResult: RemoteTranscriptionStorePurchaseResult = .cancelled
    var unfinished: [RemoteTranscriptionStoreTransaction] = []
    var all: [RemoteTranscriptionStoreTransaction] = []

    private var recordedEnvironmentCalls = 0
    private var recordedRefreshEnvironmentCalls = 0
    private var recordedEnvironmentDidComplete = false
    private var recordedProductCalls = 0
    private var recordedPurchaseCalls = 0
    private var recordedUnfinishedTransactionCalls = 0
    private var recordedAllTransactionCalls = 0
    private var recordedTransactionUpdatesCalls = 0
    private var recordedFinishedIDs: [UInt64] = []
    private var recordedSyncCalls = 0

    var environmentCalls: Int {
        lock.withLock { recordedEnvironmentCalls }
    }

    var environmentDidComplete: Bool {
        lock.withLock { recordedEnvironmentDidComplete }
    }

    var refreshEnvironmentCalls: Int {
        lock.withLock { recordedRefreshEnvironmentCalls }
    }

    var productCalls: Int {
        lock.withLock { recordedProductCalls }
    }

    var purchaseCalls: Int {
        lock.withLock { recordedPurchaseCalls }
    }

    var unfinishedTransactionCalls: Int {
        lock.withLock { recordedUnfinishedTransactionCalls }
    }

    var allTransactionCalls: Int {
        lock.withLock { recordedAllTransactionCalls }
    }

    var transactionUpdatesCalls: Int {
        lock.withLock { recordedTransactionUpdatesCalls }
    }

    var finishedIDs: [UInt64] {
        lock.withLock { recordedFinishedIDs }
    }

    var syncCalls: Int {
        lock.withLock { recordedSyncCalls }
    }

    func environment() async throws -> RemoteTranscriptionStoreEnvironment {
        try await resolveEnvironment(isRefresh: false)
    }

    func refreshEnvironment() async throws -> RemoteTranscriptionStoreEnvironment {
        try await resolveEnvironment(isRefresh: true)
    }

    private func resolveEnvironment(
        isRefresh: Bool
    ) async throws -> RemoteTranscriptionStoreEnvironment {
        let (value, delay, error) = lock.withLock {
            if isRefresh {
                recordedRefreshEnvironmentCalls += 1
            } else {
                recordedEnvironmentCalls += 1
            }
            return (environmentValue, environmentDelay, environmentError)
        }
        if let delay {
            let delayTask = Task {
                try? await Task.sleep(for: delay)
            }
            await delayTask.value
        }
        lock.withLock { recordedEnvironmentDidComplete = true }
        if let error {
            throw error
        }
        return value
    }

    func products(for identifiers: [String]) async throws -> [RemoteTranscriptionStoreProduct] {
        lock.withLock { recordedProductCalls += 1 }
        return identifiers.sorted().map { identifier in
            RemoteTranscriptionStoreProduct(
                id: identifier,
                displayName: identifier,
                displayPrice: "$0.99",
                grantSeconds: RemoteTranscriptionEmbeddedCatalog.grantSecondsByProductID[identifier] ?? 0
            )
        }
    }

    func purchase(
        productID: String,
        appAccountToken: UUID
    ) async throws -> RemoteTranscriptionStorePurchaseResult {
        lock.withLock { recordedPurchaseCalls += 1 }
        return purchaseResult
    }

    func unfinishedTransactions() async -> [RemoteTranscriptionStoreTransaction] {
        lock.withLock { recordedUnfinishedTransactionCalls += 1 }
        return unfinished
    }

    func allTransactions() async -> [RemoteTranscriptionStoreTransaction] {
        lock.withLock { recordedAllTransactionCalls += 1 }
        return all
    }

    func transactionUpdates() -> AsyncStream<RemoteTranscriptionStoreTransaction> {
        lock.withLock { recordedTransactionUpdatesCalls += 1 }
        return AsyncStream { continuation in continuation.finish() }
    }

    func finish(transactionID: UInt64) async {
        lock.withLock { recordedFinishedIDs.append(transactionID) }
    }

    func syncPurchases() async throws {
        lock.withLock { recordedSyncCalls += 1 }
    }
}
