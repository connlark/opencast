import SwiftData
import SwiftUI

/// Holds a Detect Ads or Generate tap while the one-time key notice is up.
/// Each presenting context owns one and uses it from its own actions; a
/// descendant outside that view's body (a toolbar menu) reads it from the
/// environment. The notice itself is shown by `.analysisKeyNotice(gate:)`.
@Observable final class AnalysisKeyNoticeGate {
    enum Decision {
        case later
        case addKey
    }

    struct Pending: Identifiable {
        let id = UUID()
        let action: () -> Void
    }

    /// The held tap; non-nil from the gated tap until the notice is gone.
    private(set) var pending: Pending?
    var isNoticePresented = false
    @ObservationIgnored private var decision: Decision?

    /// Runs `action` now unless the notice is due, in which case the tap is
    /// held and the notice shown. A tap while a notice is pending is ignored.
    func run(appModel: OpenCastAppModel, _ action: @escaping () -> Void) {
        guard pending == nil else {
            return
        }
        guard appModel.isAnalysisKeyNoticeDue() else {
            action()
            return
        }
        pending = Pending(action: action)
        isNoticePresented = true
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
    /// acting, so the tap runs at most once: Later runs it, Add a key opens
    /// AI Services instead, and a dismissal without a choice runs nothing.
    func didDismiss(appModel: OpenCastAppModel) {
        let action = pending?.action
        let decision = decision
        pending = nil
        self.decision = nil
        isNoticePresented = false
        switch decision {
        case .later:
            action?()
        case .addKey:
            appModel.requestAIServicesSettingsPresentation()
        case nil:
            break
        }
    }
}
