import SwiftUI

/// Footer-link presentation of one topic; related topics push inside the
/// sheet's own stack.
struct HelpTopicSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let topicID: String

    var body: some View {
        NavigationStack {
            HelpTopicView(topicID: topicID)
                .withOpenCastDestinations()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
        .task {
            await appModel.helpContent.refreshIfNeeded()
        }
    }
}
