import SwiftData
import SwiftUI

/// Where Detect Ads passes run. "Ask First Time" (no stored preference)
/// re-arms the first-tap dialog; the cloud choice appears only when the
/// remote transcription surface is visible at all.
struct SettingsAdDetectionSection: View {
    private enum ModeChoice: String, CaseIterable, Identifiable {
        case ask
        case onDevice
        case cloud

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .ask: "Ask First Time"
            case .onDevice: "On This Device"
            case .cloud: "In the Cloud"
            }
        }

        var mode: AdDetectionMode? {
            switch self {
            case .ask: nil
            case .onDevice: .onDevice
            case .cloud: .cloud
            }
        }

        init(mode: AdDetectionMode?) {
            switch mode {
            case nil: self = .ask
            case .onDevice: self = .onDevice
            case .cloud: self = .cloud
            }
        }
    }

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var choice: ModeChoice = .ask

    var body: some View {
        Section {
            Picker("Detect Ads", selection: $choice) {
                ForEach(availableChoices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .onChange(of: choice) { _, newChoice in
                applyChoice(newChoice)
            }
            .onChange(of: appModel.adDetectionSettings.mode) { _, storeMode in
                syncChoice(with: storeMode)
            }

            if let message = appModel.adDetectionSettings.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Detect Ads")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if choice == .cloud {
                    Text(cloudFooterText)
                }
                HelpFooterLink(title: "How ad detection works", topicID: HelpTopicID.adDetection)
            }
        }
        .task {
            choice = ModeChoice(mode: appModel.adDetectionSettings.mode)
        }
    }

    private var cloudFooterText: String {
        guard let balance = appModel.remoteTranscriptionPurchases.balance else {
            return "Uses transcription hours."
        }
        return "Uses transcription hours. \(RemoteTranscriptionBalanceFormatting.hours(balance.availableSeconds)) remaining."
    }

    private var availableChoices: [ModeChoice] {
        appModel.remoteTranscriptionPurchases.isSurfaceVisible
            ? ModeChoice.allCases
            : [.ask, .onDevice]
    }

    private func applyChoice(_ newChoice: ModeChoice) {
        guard !appModel.adDetectionSettings.setMode(newChoice.mode, modelContext: modelContext) else {
            return
        }

        // The store reverted; pull the picker back so the control and the
        // persisted preference cannot silently diverge.
        choice = ModeChoice(mode: appModel.adDetectionSettings.mode)
    }

    private func syncChoice(with storeMode: AdDetectionMode?) {
        let storeChoice = ModeChoice(mode: storeMode)
        guard choice != storeChoice else {
            return
        }

        choice = storeChoice
    }
}
