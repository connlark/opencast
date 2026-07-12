import SwiftUI

struct SettingsAppleSpeechSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var sectionTitle = "Apple Speech Assets"

    var body: some View {
        Section {
            LabeledContent {
                Text(statusText)
            } label: {
                Label("Status", systemImage: statusSystemImage)
            }

            if case .installing(_, let fractionCompleted) = appModel.appleSpeechAssets.state {
                ProgressView(value: min(max(fractionCompleted, 0), 1))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Speech asset download progress")
            }

            Button("Check Speech Assets", systemImage: "arrow.clockwise", action: checkAssets)
                .disabled(isBusy)
        } header: {
            Text(sectionTitle)
        } footer: {
            Text("Debug status for Apple's on-device speech engine.")
        }
        .task {
            await refreshIfUnknown()
        }
    }

    private var statusText: String {
        switch appModel.appleSpeechAssets.state {
        case .unknown, .checking:
            return "Checking"
        case .unavailable:
            return "Unavailable"
        case .ready(let installedLocaleIdentifiers):
            guard !installedLocaleIdentifiers.isEmpty else {
                return "Ready to download"
            }
            let locales = installedLocaleIdentifiers
                .map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
                .sorted()
                .joined(separator: ", ")
            return "Installed — \(locales)"
        case .installing:
            return "Downloading"
        case .failed(let message):
            return message
        }
    }

    private var statusSystemImage: String {
        switch appModel.appleSpeechAssets.state {
        case .ready(let installedLocaleIdentifiers) where !installedLocaleIdentifiers.isEmpty:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .installing, .checking:
            "clock"
        case .unknown, .unavailable, .ready:
            "waveform"
        }
    }

    private var isBusy: Bool {
        switch appModel.appleSpeechAssets.state {
        case .checking, .installing:
            true
        case .unknown, .unavailable, .ready, .failed:
            false
        }
    }

    private func checkAssets() {
        Task {
            await appModel.appleSpeechAssets.refresh()
        }
    }

    private func refreshIfUnknown() async {
        guard case .unknown = appModel.appleSpeechAssets.state else {
            return
        }
        await appModel.appleSpeechAssets.refresh()
    }
}
