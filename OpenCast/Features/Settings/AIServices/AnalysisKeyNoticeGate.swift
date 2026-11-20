import SwiftData
import SwiftUI

/// Each presenting context owns one gate; a descendant outside that view's body, such as a
/// toolbar menu, reads it from the environment.
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
    /// Presented from this gate's context, so it also works over Now Playing.
    var helpDestination: SheetDestination?
    @ObservationIgnored private var decision: Decision?

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

    /// The choice takes effect in `didDismiss`, once the sheet is gone.
    func choose(_ decision: Decision, appModel: OpenCastAppModel, modelContext: ModelContext) {
        guard pending != nil, self.decision == nil else {
            return
        }
        self.decision = decision
        appModel.analysisKeyNotice.markSeen(modelContext: modelContext)
        isNoticePresented = false
    }

    /// Clears the held tap and the choice before acting, so the tap runs at most once.
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
