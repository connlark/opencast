import Foundation
import OpenCastTranscription
import OSLog

@Observable
final class RemoteTranscriptionPurchaseStore {
    private static let appTransactionLogger = Logger(
        subsystem: "com.connor.opencast",
        category: "RemoteTranscriptionAppTransaction"
    )

    enum Availability: Equatable {
        case unknown
        case unavailable(reason: String)
        case storeDisabled(reason: String)
        case available
    }

    enum PurchasePhase: Equatable {
        case idle
        case purchasing(productID: String)
        case pendingApproval
        case completed(creditedSeconds: Int64)
        case failed(message: String)
    }

    private(set) var availability: Availability = .unknown

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

    /// Fires after the larger balance is in place.
    @ObservationIgnored var onBalanceIncreased: (() -> Void)?

    @ObservationIgnored private var appAccountToken: UUID?
    @ObservationIgnored private var redeemedTransactionIDs: Set<UInt64> = []
    @ObservationIgnored private var requestedRefundTransactionIDs: Set<UInt64> = []
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Bool, Never>?
    @ObservationIgnored private var redemptionRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRedemptionRetries: [UInt64: RemoteTranscriptionStoreTransaction] = [:]
    #if DEBUG
    @ObservationIgnored private var usesUIFixture = false
    #endif

    private let api: any RemoteTranscriptionAPI
    private let storeKit: any RemoteTranscriptionStoreKitClient
    private let redemptionRetryDelays: [Duration]
    private let configurationResolver: (Bool) async -> RemoteTranscriptionBackendConfiguration

    init(
        api: any RemoteTranscriptionAPI,
        storeKit: any RemoteTranscriptionStoreKitClient,
        configuration: RemoteTranscriptionBackendConfiguration? = nil,
        configurationResolver: ((Bool) async -> RemoteTranscriptionBackendConfiguration)? = nil,
        redemptionRetryDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
    ) {
        self.api = api
        self.storeKit = storeKit
        self.redemptionRetryDelays = redemptionRetryDelays
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
        redemptionRetryTask?.cancel()
    }

    func prepare() async {
        #if DEBUG
        if usesUIFixture { return }
        #endif
        await runPreparation(refreshAppTransaction: false)
    }

    /// `AppTransaction.refresh()` may present App Store authentication, so only an explicit
    /// user action may call this.
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
        // A caller's cancellation must not cancel the shared task: a sheet that disappears
        // mid-flight would strand `availability` at `.unknown` for the whole session.
        if let prepareTask {
            _ = await prepareTask.value
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
        // Two concurrent StoreKit flows would clobber each other's purchasePhase.
        guard !isPurchaseInFlight else { return }
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
                } else if redeemedTransactionIDs.contains(transaction.id) {
                    // The updates listener can redeem this transaction while `purchase()` is
                    // suspended; its credit is success, not a redeem failure.
                    let creditedSeconds = RemoteTranscriptionEmbeddedCatalog
                        .grantSecondsByProductID[transaction.productID]
                        ?? product.grantSeconds
                    purchasePhase = .completed(creditedSeconds: creditedSeconds)
                } else {
                    purchasePhase = .failed(message: String(localized: "The purchase completed but couldn’t be credited yet. It will retry automatically."))
                    scheduleRedemptionRetry(transaction)
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

    var isPurchaseInFlight: Bool {
        switch purchasePhase {
        case .purchasing, .pendingApproval:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    /// Only on an explicit user gesture: it runs `AppStore.sync()`.
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

    /// Returns false when the refresh failed or was cancelled; the kept balance is then not new.
    /// The session's first balance is not a top-up, so it wakes nothing.
    @discardableResult
    func refreshBalance() async -> Bool {
        #if DEBUG
        if usesUIFixture { return false }
        #endif
        // An answer that arrives after cancellation (a data nuke mid-sweep) must apply and wake
        // nothing.
        guard let response = try? await api.bootstrap(), !Task.isCancelled else { return false }
        let previousBalance = balance
        apply(bootstrap: response)
        if let previousBalance,
           purchaseHeadroom(response.balance) > purchaseHeadroom(previousBalance) {
            onBalanceIncreased?()
        }
        return true
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

    /// Only a terminal phase clears: `purchasing` guards against a double-buy, and the updates
    /// listener resolves `pendingApproval`.
    func dismissPurchasePhase() {
        switch purchasePhase {
        case .completed, .failed:
            purchasePhase = .idle
        case .idle, .purchasing, .pendingApproval:
            break
        }
    }

    #if DEBUG
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

    /// Mirrors the server's reserve arithmetic; transcription charges audio seconds 1:1.
    func estimate(durationSeconds: Double) -> RemoteTranscriptionConsumptionEstimate {
        estimate(chargeSeconds: Int64(durationSeconds.rounded(.up)))
    }

    /// Display only; the worker recomputes the charge from its own duration at reserve.
    func analysisEstimate(durationSeconds: Double) -> RemoteTranscriptionConsumptionEstimate? {
        guard let chargeSeconds = TranscriptAnalysisBillingRate.estimatedChargeSeconds(
            durationSeconds: durationSeconds
        ) else {
            return nil
        }
        return estimate(chargeSeconds: chargeSeconds)
    }

    /// The server prices the declared duration or the last segment end, whichever is larger.
    func analysisEstimate(transcript document: EpisodeTranscriptDocument) -> RemoteTranscriptionConsumptionEstimate? {
        analysisEstimate(durationSeconds: max(document.audioDuration, document.segments.last?.end ?? 0))
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

    /// Returns whether the outcome is cached for the session; a retryable failure is not.
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
            return false
        }
        apply(bootstrap: bootstrap)

        guard configuration.requiresAppTransaction else {
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
                let wasPendingApproval = self.purchasePhase == .pendingApproval
                if let response = await self.redeemAndFinish(transaction) {
                    if wasPendingApproval {
                        self.purchasePhase = .completed(creditedSeconds: response.creditedSeconds)
                    }
                } else if !self.redeemedTransactionIDs.contains(transaction.id) {
                    self.scheduleRedemptionRetry(transaction)
                }
            }
        }
    }

    // MARK: - Crediting

    private func reconcile(_ transactions: [RemoteTranscriptionStoreTransaction]) async {
        for transaction in transactions {
            if await redeemAndFinish(transaction) == nil,
               !redeemedTransactionIDs.contains(transaction.id) {
                scheduleRedemptionRetry(transaction)
            }
        }
    }

    private func scheduleRedemptionRetry(_ transaction: RemoteTranscriptionStoreTransaction) {
        pendingRedemptionRetries[transaction.id] = transaction
        guard redemptionRetryTask == nil, !redemptionRetryDelays.isEmpty else {
            return
        }

        let delays = redemptionRetryDelays
        redemptionRetryTask = Task { [weak self] in
            for delay in delays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                await self.retryPendingRedemptions()
                if self.pendingRedemptionRetries.isEmpty {
                    break
                }
            }
            self?.redemptionRetryTask = nil
        }
    }

    private func retryPendingRedemptions() async {
        for transaction in Array(pendingRedemptionRetries.values) {
            let shouldPresentCompletion: Bool = switch purchasePhase {
            case .failed, .pendingApproval: true
            case .idle, .purchasing, .completed: false
            }
            guard let response = await redeemAndFinish(transaction) else {
                continue
            }
            if shouldPresentCompletion {
                purchasePhase = .completed(creditedSeconds: response.creditedSeconds)
            }
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

    /// Finishes the transaction only on an acknowledged outcome; an unfinished one is retried at
    /// the next launch or refresh.
    @discardableResult
    private func redeemAndFinish(
        _ transaction: RemoteTranscriptionStoreTransaction
    ) async -> OpenCastRemoteTranscriptionRedeemResponse? {
        guard !redeemedTransactionIDs.contains(transaction.id) else {
            // A reconcile sweep can redeem an approved transaction before the updates listener
            // sees it; the pending row must not outlive the credit.
            clearPendingApprovalPhase()
            return nil
        }
        do {
            let response = try await api.redeem(transactionJWS: transaction.jwsRepresentation)
            guard response.outcome.isFinishable else { return nil }
            redeemedTransactionIDs.insert(transaction.id)
            await storeKit.finish(transactionID: transaction.id)
            let previousBalance = balance
            balance = response.balance
            pendingRedemptionRetries.removeValue(forKey: transaction.id)
            // A lost first response makes the retry answer `alreadyCredited` while this process
            // sees the added headroom for the first time, so an increase also wakes deferred work.
            let observedHeadroomIncrease = previousBalance.map {
                purchaseHeadroom(response.balance) > purchaseHeadroom($0)
            } ?? false
            if response.outcome == .credited || observedHeadroomIncrease {
                onBalanceIncreased?()
            }
            clearPendingApprovalPhase()
            return response
        } catch {
            return nil
        }
    }

    /// Any acknowledged redeem clears `pendingApproval`: the listener's own attempt can fail
    /// offline or lose to a reconcile sweep.
    private func clearPendingApprovalPhase() {
        if purchasePhase == .pendingApproval {
            purchasePhase = .idle
        }
    }

    private func purchaseHeadroom(_ balance: OpenCastRemoteTranscriptionBalance) -> Int64 {
        balance.availableSeconds
            + RemoteTranscriptionEmbeddedCatalog.debtCapSeconds
            - min(balance.debtSeconds, RemoteTranscriptionEmbeddedCatalog.debtCapSeconds)
            - balance.reservedSeconds
    }
}
