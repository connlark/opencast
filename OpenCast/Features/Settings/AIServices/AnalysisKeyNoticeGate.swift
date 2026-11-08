import SwiftData
import SwiftUI

/// Holds a Detect Ads or Generate tap while the one-time key notice is up, or
/// while it is not yet known whether the notice is due. Each presenting
/// context owns one and uses it from its own actions; a descendant outside
/// that view's body (a toolbar menu) reads it from the environment. The
/// notice itself is shown by `.analysisKeyNotice(gate:)`.
@Observable final class AnalysisKeyNoticeGate {
    enum Decision {
        case ok
        case learnMore
    }

    struct Pending: Identifiable {
        let id = UUID()
        let action: () -> Void
    }

    /// The held tap; non-nil from the gated tap until the notice is gone.
    private(set) var pending: Pending?
    var isNoticePresented = false
    /// The help topic Learn More opens, presented from this gate's context
    /// so it also works over Now Playing.
    var helpDestination: SheetDestination?
    @ObservationIgnored private var decision: Decision?

    /// Runs `action` now unless the notice is due, in which case the tap is
    /// held and the notice shown. While reachability is unknown the tap is
    /// held until it resolves. A tap while one is held is ignored.
    func run(appModel: OpenCastAppModel, _ action: @escaping () -> Void) {
        guard pending == nil else {
            return
        }
        if appModel.isAnalysisKeyNoticeDue() {
            pending = Pending(action: action)
            isNoticePresented = true
        } else if appModel.isAnalysisKeyNoticeAwaitingReachability() {
            let held = Pending(action: action)
            pending = held
            Task { [weak self] in
                await appModel.analysisTrialReachability.resolve()
                self?.reachabilityResolved(held, appModel: appModel)
            }
        } else {
            action()
        }
    }

    /// No sheet means no `didDismiss`, so the held tap is cleared here.
    private func reachabilityResolved(_ held: Pending, appModel: OpenCastAppModel) {
        guard pending?.id == held.id else {
            return
        }
        if appModel.isAnalysisKeyNoticeDue() {
            isNoticePresented = true
        } else {
            pending = nil
            held.action()
        }
    }

    /// Records the listener's choice, marks the notice seen and dismisses it.
    /// The choice takes effect in `didDismiss`, once the sheet is gone.
    func choose(_ decision: Decision, appModel: OpenCastAppModel, modelContext: ModelContext) {
        guard pending != nil, self.decision == nil else {
            return
        }
        self.decision = decision
        appModel.analysisKeyNotice.markSeen(modelContext: modelContext)
        isNoticePresented = false
    }

    /// The sheet's `onDismiss`. Clears the held tap and the choice before
    /// acting, so the tap runs at most once: OK runs it, Learn More opens the
    /// help instead, and a dismissal without a choice runs nothing.
    func didDismiss() {
        let action = pending?.action
        let decision = decision
        pending = nil
        self.decision = nil
        isNoticePresented = false
        switch decision {
        case .ok:
            action?()
        case .learnMore:
            helpDestination = .helpTopic(id: HelpTopicID.aiKeys)
        case nil:
            break
        }
    }
}
