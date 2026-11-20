import SwiftUI

struct TranscriptIntelligenceDisclosureView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(TranscriptIntelligenceDisclosureCopy.title, systemImage: "apple.intelligence")
        } description: {
            Text(TranscriptIntelligenceDisclosureCopy.body)
        } actions: {
            Button(TranscriptIntelligenceDisclosureCopy.confirmButtonTitle, action: onContinue)
                .buttonStyle(.glassProminent)
            Button("Not Now", action: onCancel)
        }
    }
}
