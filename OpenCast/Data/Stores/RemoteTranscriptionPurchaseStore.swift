import Foundation
import OpenCastTranscription
import OSLog

/// Purchase + balance state for remote transcription.
/// Money invariants live here: the catalog cross-check fails closed, a
/// transaction is finished ONLY after the server acknowledges the credit
/// (credited / already credited / refunded), and reconciliation retries
/// unfinished transactions at launch and behind an explicit user refresh.
@Observable
final class RemoteTranscriptionPurchaseStore {
    private static let appTransactionLogger = Logger(
        subsystem: "com.connor.opencast",
        category: "RemoteTranscriptionAppTransaction"
    )

    enum Availability: Equatable {
        /// Gate not resolved yet (first `prepare()` still running).
        case unknown
        /// No trustworthy backend lane could be resolved yet. Settings keeps
        /// this visible so an explicit AppTransaction refresh can recover.
        case unavailable(reason: String)
        /// Surfaces show balance/status but purchasing is off (dev lane,
        /// kill switch, or a fail-closed catalog mismatch).
        case storeDisabled(reason: String)
        case available
    }

    enum PurchasePhase: Equatable {
        case idle
        case purchasing(productID: String)
        /// Deferred approval (Ask to Buy); credit lands via the updates
        /// listener when approved.
        case pendingApproval
        case completed(creditedSeconds: Int64)
        case failed(message: String)
    }

    private(set) var availability: Availability = .unknown

    /// Synchronous gate for remote-transcription surfaces: the
    /// DEBUG dev flag opens them immediately (fixtures/UI tests never wait on
    /// resolution); otherwise the async StoreKit-environment gate decides.
    var isSurfaceVisible: Bool {
        if RemoteTranscriptionDevFlag.isEnabled { return true }
        switch availability {
        case .unknown, .unavailable: return false
        case .storeDisabled, .available: return true
        }
    }
    private(set) var products: [RemoteTranscriptionStoreProduct] = []
    private(set) var balance: OpenCastRemoteTranscriptionBalance?
    private(set) var accountID: String?
    private(set) var purchasePhase: PurchasePhase = .idle
    private(set) var isRefreshing = false
    private(set) var refundCandidates: [RemoteTranscriptionRefundCandidate] = []

    /// Fires after a redeem lands seconds on the account, so balance-
    /// deferred work (the Chapters & Summary pay gate) can re-probe (H8).
    @ObservationIgnored var onBalanceIncreased: (() -> Void)?

    @ObservationIgnored private var appAccountToken: UUID?
    @ObservationIgnored private var redeemedTransactionIDs: Set<UInt64> = []
    @ObservationIgnored private var requestedRefundTransactionIDs: Set<UInt64> = []
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Bool, Never>?
    #if DEBUG
    @ObservationIgnored private var usesUIFixture = false
    #endif

    private let api: any RemoteTranscriptionAPI
    private let storeKit: any RemoteTranscriptionStoreKitClient
    /// Tests and DEBUG fixtures pin a lane without StoreKit work. Release app
    /// wiring resolves from the shared AppTransaction snapshot.
    private let configurationResolver: (Bool) async -> RemoteTranscriptionBackendConfiguration

    init(
        api: any RemoteTranscriptionAPI,
        storeKit: any RemoteTranscriptionStoreKitClient,
        configuration: RemoteTranscriptionBackendConfiguration? = nil,
        configurationResolver: ((Bool) async -> RemoteTranscriptionBackendConfiguration)? = nil
    ) {
        self.api = api
        self.storeKit = storeKit
        if let configurationResolver {
            self.configurationResolver = configurationResolver
        } else if let configuration {
            self.configurationResolver = { _ in configuration }
        } else {
            #if DEBUG
            self.configurationResolver = { _ in .current }
            #else
            self.configurationResolver = { refreshAppTransaction in
                let environment = await Self.resolvedEnvironment(
                    storeKit: storeKit,
                    refresh: refreshAppTransaction
                )
                return .release(for: environment)
            }
            #endif
        }
    }

    deinit {
        updatesTask?.cancel()
        prepareTask?.cancel()
    }

    /// Idempotent: resolves the gate, bootstraps, cross-checks the catalog,
    /// loads products, starts the updates listener, and reconciles
    /// unfinished transactions once.
    func prepare() async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        await runPreparation(refreshAppTransaction: false)
    }

    /// Explicit Settings action. AppTransaction.refresh() may authenticate,
    /// so this path must never be invoked by launch preparation.
    func retryPreparation() async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        guard case .unavailable = availability else { return }

        prepareTask?.cancel()
        prepareTask = nil
        products = []
        balance = nil
        accountID = nil
        appAccountToken = nil
        refundCandidates = []
        availability = .unknown
        await runPreparation(refreshAppTransaction: true)
    }

    private func runPreparation(refreshAppTransaction: Bool) async {
        // No caller's cancellation may cancel the shared preparation: the
        // app root awaits the same task, and a transient surface (settings
        // sheet, chapters card) disappearing mid-flight would otherwise
        // strand availability at .unknown for the whole session. The work is
        // bounded (bootstrap + products load under network timeouts), so a
        // cancelled caller simply keeps waiting and the result is cached for
        // everyone. retryPreparation and deinit still cancel explicitly.
        if let prepareTask {
            await prepareTask.value
            return
        }
        let task = Task { await resolve(refreshAppTransaction: refreshAppTransaction) }
        prepareTask = task
        let shouldCache = await task.value
        if !shouldCache {
            prepareTask = nil
        }
    }

    func purchase(_ product: RemoteTranscriptionStoreProduct) async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        guard case .available = availability else { return }
        // Any in-flight purchase blocks a second one: two concurrent StoreKit
        // flows would clobber each other's purchasePhase.
        if case .purchasing = purchasePhase { return }
        guard let appAccountToken else {
            purchasePhase = .failed(message: String(localized: "Purchases aren’t ready yet. Try again in a moment."))
            return
        }
        purchasePhase = .purchasing(productID: product.id)
        do {
            let result = try await storeKit.purchase(
                productID: product.id,
                appAccountToken: appAccountToken
            )
            switch result {
            case .success(let transaction):
                updateRefundCandidate(transaction)
                if let response = await redeemAndFinish(transaction) {
                    purchasePhase = .completed(creditedSeconds: response.creditedSeconds)
                } else {
                    purchasePhase = .failed(message: String(localized: "The purchase completed but couldn’t be credited yet. It will retry automatically."))
                }
            case .pending:
                purchasePhase = .pendingApproval
            case .cancelled:
                purchasePhase = .idle
            case .unverified:
                purchasePhase = .failed(message: String(localized: "The App Store couldn’t verify this purchase."))
            }
        } catch is CancellationError {
            purchasePhase = .idle
        } catch {
            purchasePhase = .failed(message: error.localizedDescription)
        }
    }

    /// Explicit user gesture: `AppStore.sync()` plus a full-history
    /// reconciliation sweep.
    func refreshPurchases() async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await storeKit.syncPurchases()
        } catch is CancellationError {
            return
        } catch {
            // Sync is best-effort; reconciliation below still runs.
        }
        let unfinished = await storeKit.unfinishedTransactions()
        let all = await storeKit.allTransactions()
        await reconcile(unfinished)
        await reconcile(all)
        mergeRefundCandidates(all)
        await refreshBalance()
        dismissPurchasePhase()
    }

    func refreshBalance() async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        guard let response = try? await api.bootstrap() else { return }
        apply(bootstrap: response)
    }

    func refreshRefundCandidates() async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        mergeRefundCandidates(await storeKit.allTransactions())
    }

    func markRefundRequested(transactionID: UInt64) {
        requestedRefundTransactionIDs.insert(transactionID)
        refundCandidates.removeAll { $0.id == transactionID }
    }

    /// Clears a terminal purchase row (`completed`/`failed`). In-flight
    /// phases stay put: `purchasing` guards against a double-buy and
    /// `pendingApproval` is resolved by the transaction-updates listener.
    func dismissPurchasePhase() {
        switch purchasePhase {
        case .completed, .failed:
            purchasePhase = .idle
        case .idle, .purchasing, .pendingApproval:
            break
        }
    }

    #if DEBUG
    /// Deterministic App Review capture state. It is launch-argument-only,
    /// never contacts StoreKit/the backend, and cannot compile into Release.
    func applyReviewScreenshotFixture() {
        let presentationByProductID: [String: (displayName: String, displayPrice: String)] = [
            "com.connor.opencast.transcription.hours20.v1": (
                displayName: "20 Transcription Hours",
                displayPrice: "$0.99"
            ),
            "com.connor.opencast.transcription.hours100.v1": (
                displayName: "100 Transcription Hours",
                displayPrice: "$4.99"
            ),
        ]

        usesUIFixture = true
        availability = .available
        products = RemoteTranscriptionEmbeddedCatalog.products.map { catalogProduct in
            guard let presentation = presentationByProductID[catalogProduct.productID] else {
                preconditionFailure(
                    "Missing App Review presentation metadata for \(catalogProduct.productID)"
                )
            }
            return RemoteTranscriptionStoreProduct(
                id: catalogProduct.productID,
                displayName: presentation.displayName,
                displayPrice: presentation.displayPrice,
                grantSeconds: catalogProduct.grantSeconds
            )
        }
        balance = OpenCastRemoteTranscriptionBalance(
            availableSeconds: 3_600,
            reservedSeconds: 0,
            debtSeconds: 0
        )
        accountID = "fixture-review-account"
        appAccountToken = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
    }

    func applyUnavailableFixture() {
        usesUIFixture = true
        availability = .unavailable(
            reason: String(localized: "Connect to the App Store and check your internet connection, then try again.")
        )
    }

    func applyDelayedAvailabilityFixture() {
        usesUIFixture = true
        availability = .unknown
    }
    #endif

    /// Consumption preview for the pre-create sheet, mirroring the server's
    /// reserve arithmetic. Transcription charges audio-seconds 1:1.
    func estimate(durationSeconds: Double) -> RemoteTranscriptionConsumptionEstimate {
        estimate(chargeSeconds: Int64(durationSeconds.rounded(.up)))
    }

    /// Chapters & Summary preview (the H6 unit bridge): analysis charges the
    /// flat blended rate per audio-hour, then settles against the same
    /// shared balance (H7). Nil when the duration cannot price a run.
    /// Display-only — the worker recomputes the charge from its own
    /// authoritative duration at reserve.
    func analysisEstimate(durationSeconds: Double) -> RemoteTranscriptionConsumptionEstimate? {
        guard let chargeSeconds = TranscriptAnalysisBillingRate.estimatedChargeSeconds(
            durationSeconds: durationSeconds
        ) else {
            return nil
        }
        return estimate(chargeSeconds: chargeSeconds)
    }

    private func estimate(chargeSeconds: Int64) -> RemoteTranscriptionConsumptionEstimate {
        let estimated = chargeSeconds
        let available = balance?.availableSeconds ?? 0
        let reserved = balance?.reservedSeconds ?? 0
        let debt = balance?.debtSeconds ?? 0
        let cap = RemoteTranscriptionEmbeddedCatalog.debtCapSeconds
        let headroom = available + (cap - min(debt, cap)) - reserved
        let spendable = max(available - reserved, 0)
        return RemoteTranscriptionConsumptionEstimate(
            estimatedSeconds: estimated,
            availableSeconds: available,
            reservedSeconds: reserved,
            debtSeconds: debt,
            overdraftSeconds: max(estimated - spendable, 0),
            fitsWithinHeadroom: estimated <= headroom
        )
    }

    // MARK: - Preparation

    /// Returns false only when environment resolution is retryable. Successful
    /// resolution remains coalesced even when the backend or store is disabled.
    private func resolve(refreshAppTransaction: Bool) async -> Bool {
        let configuration = await configurationResolver(refreshAppTransaction)
        guard !Task.isCancelled else { return false }
        guard configuration.isEnabled else {
            availability = .unavailable(
                reason: String(localized: "Connect to the App Store and check your internet connection, then try again.")
            )
            return false
        }

        let bootstrap: OpenCastRemoteTranscriptionBootstrapResponse
        do {
            bootstrap = try await api.bootstrap()
        } catch is CancellationError {
            return false
        } catch {
            availability = .storeDisabled(reason: String(localized: "The transcription service can’t be reached right now."))
            return true
        }
        apply(bootstrap: bootstrap)

        guard configuration.requiresAppTransaction else {
            // Development lane: balance surfaces only, no store.
            availability = .storeDisabled(reason: String(localized: "Purchases aren’t available in this configuration."))
            return true
        }
        guard RemoteTranscriptionEmbeddedCatalog.matches(
            serverCatalog: bootstrap.catalog,
            serverHash: bootstrap.catalogSHA256
        ) else {
            // Fail closed: never sell against a drifted catalog.
            availability = .storeDisabled(reason: String(localized: "The store is temporarily unavailable."))
            return true
        }
        guard bootstrap.purchasesEnabled == true else {
            availability = .storeDisabled(reason: String(localized: "Purchases are temporarily unavailable."))
            return true
        }

        do {
            let loaded = try await storeKit.products(for: RemoteTranscriptionEmbeddedCatalog.productIDs)
            guard Set(loaded.map(\.id)) == Set(RemoteTranscriptionEmbeddedCatalog.productIDs) else {
                availability = .storeDisabled(reason: String(localized: "The store is temporarily unavailable."))
                return true
            }
            products = loaded
        } catch is CancellationError {
            return false
        } catch {
            availability = .storeDisabled(reason: String(localized: "Store products couldn’t be loaded."))
            return true
        }

        guard !Task.isCancelled else { return false }
        availability = .available
        startUpdatesListener()
        let unfinished = await storeKit.unfinishedTransactions()
        for transaction in unfinished {
            updateRefundCandidate(transaction)
        }
        await reconcile(unfinished)
        return true
    }

    /// Silent launch lookup stays bounded. An explicit refresh may present
    /// App Store authentication, so only caller cancellation bounds that path.
    static func resolvedEnvironment(
        storeKit: any RemoteTranscriptionStoreKitClient,
        refresh: Bool = false,
        timeout: Duration = .seconds(15)
    ) async -> RemoteTranscriptionStoreEnvironment {
        let clock = ContinuousClock()
        let start = clock.now

        if refresh {
            let outcome: (environment: RemoteTranscriptionStoreEnvironment, category: String)
            do {
                outcome = (try await storeKit.refreshEnvironment(), "success")
            } catch is CancellationError {
                outcome = (.unknown("unavailable"), "cancelled")
            } catch {
                outcome = (.unknown("unavailable"), "error")
            }
            logAppTransactionResolution(
                operation: "refresh",
                elapsed: start.duration(to: clock.now),
                category: outcome.category,
                environment: outcome.environment
            )
            return outcome.environment
        }

        let (results, continuation) = AsyncStream<(
            RemoteTranscriptionStoreEnvironment,
            String
        )>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let lookupTask = Task {
            let outcome: (RemoteTranscriptionStoreEnvironment, String)
            do {
                outcome = (try await storeKit.environment(), "success")
            } catch is CancellationError {
                outcome = (.unknown("unavailable"), "cancelled")
            } catch {
                outcome = (.unknown("unavailable"), "error")
            }
            continuation.yield(outcome)
            continuation.finish()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            continuation.yield((.unknown("unavailable"), "timeout"))
            continuation.finish()
        }
        continuation.onTermination = { _ in
            lookupTask.cancel()
            timeoutTask.cancel()
        }

        let outcome: (environment: RemoteTranscriptionStoreEnvironment, category: String) =
            await withTaskCancellationHandler {
                for await result in results {
                    return (result.0, result.1)
                }
                return (
                    .unknown("unavailable"),
                    Task.isCancelled ? "cancelled" : "error"
                )
            } onCancel: {
                continuation.finish()
            }
        logAppTransactionResolution(
            operation: "shared",
            elapsed: start.duration(to: clock.now),
            category: outcome.category,
            environment: outcome.environment
        )
        return outcome.environment
    }

    private static func logAppTransactionResolution(
        operation: String,
        elapsed: Duration,
        category: String,
        environment: RemoteTranscriptionStoreEnvironment
    ) {
        let components = elapsed.components
        let elapsedMilliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        let environmentName: String = switch environment {
        case .sandbox: "sandbox"
        case .xcode: "xcode"
        case .production: "production"
        case .unknown: "unknown"
        }
        appTransactionLogger.info(
            "AppTransaction operation=\(operation, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public) result=\(category, privacy: .public) environment=\(environmentName, privacy: .public)"
        )
    }

    private func apply(bootstrap: OpenCastRemoteTranscriptionBootstrapResponse) {
        accountID = bootstrap.accountID
        balance = bootstrap.balance
        appAccountToken = bootstrap.appAccountToken.flatMap(UUID.init(uuidString:))
    }

    private func startUpdatesListener() {
        guard updatesTask == nil else { return }
        let stream = storeKit.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await transaction in stream {
                guard let self else { return }
                self.updateRefundCandidate(transaction)
                await self.redeemAndFinish(transaction)
            }
        }
    }

    // MARK: - Crediting

    private func reconcile(_ transactions: [RemoteTranscriptionStoreTransaction]) async {
        for transaction in transactions {
            await redeemAndFinish(transaction)
        }
    }

    private func mergeRefundCandidates(
        _ transactions: [RemoteTranscriptionStoreTransaction]
    ) {
        for transaction in transactions {
            updateRefundCandidate(transaction)
        }
    }

    private func updateRefundCandidate(_ transaction: RemoteTranscriptionStoreTransaction) {
        refundCandidates.removeAll { $0.id == transaction.id }
        guard let candidate = refundCandidate(from: transaction) else { return }
        refundCandidates.append(candidate)
        refundCandidates.sort { $0.purchaseDate > $1.purchaseDate }
    }

    private func refundCandidate(
        from transaction: RemoteTranscriptionStoreTransaction
    ) -> RemoteTranscriptionRefundCandidate? {
        guard transaction.isVerified else { return nil }
        guard RemoteTranscriptionEmbeddedCatalog.productIDs.contains(transaction.productID) else {
            return nil
        }
        guard transaction.revocationDate == nil else { return nil }
        guard requestedRefundTransactionIDs.contains(transaction.id) == false else { return nil }
        guard let purchaseDate = transaction.purchaseDate else { return nil }
        return RemoteTranscriptionRefundCandidate(
            id: transaction.id,
            productID: transaction.productID,
            purchaseDate: purchaseDate
        )
    }

    /// Exactly-once client half of crediting: redeem against the server and
    /// finish ONLY on an acknowledged outcome. Failures leave the
    /// transaction unfinished so a later launch or refresh retries.
    @discardableResult
    private func redeemAndFinish(
        _ transaction: RemoteTranscriptionStoreTransaction
    ) async -> OpenCastRemoteTranscriptionRedeemResponse? {
        guard !redeemedTransactionIDs.contains(transaction.id) else {
            // A reconcile sweep may have redeemed the approved transaction
            // before the updates listener saw it; the pending row must not
            // outlive the credit.
            clearPendingApprovalPhase()
            return nil
        }
        do {
            let response = try await api.redeem(transactionJWS: transaction.jwsRepresentation)
            guard response.outcome.isFinishable else { return nil }
            redeemedTransactionIDs.insert(transaction.id)
            await storeKit.finish(transactionID: transaction.id)
            balance = response.balance
            // The server echoes the original positive creditedSeconds for
            // already_credited and refunded acknowledgements; only a fresh
            // credit means the balance actually went up.
            if response.outcome == .credited {
                onBalanceIncreased?()
            }
            clearPendingApprovalPhase()
            return response
        } catch {
            return nil
        }
    }

    /// pendingApproval clears on any acknowledged redeem, not only the
    /// updates listener's own attempt — a failed first attempt (offline at
    /// approval time) or a reconcile-sweep win would otherwise strand the
    /// "awaiting approval" row for the rest of the session.
    private func clearPendingApprovalPhase() {
        if purchasePhase == .pendingApproval {
            purchasePhase = .idle
        }
    }
}
