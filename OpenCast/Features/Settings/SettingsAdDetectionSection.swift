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
            .onChange(of: choice) { _, newChoice in
                appModel.adDetectionSettings.setMode(newChoice.mode, modelContext: modelContext)
            }
        } footer: {
            if choice == .cloud, let balance = appModel.remoteTranscriptionPurchases.balance {
                Text(
                    "Cloud detection uses transcription credits and delivers the transcript too. \(RemoteTranscriptionBalanceFormatting.hours(balance.availableSeconds)) remaining."
                )
            } else if choice == .cloud {
                Text("Cloud detection uses transcription credits and delivers the transcript too.")
            }
        }
        .task {
            choice = ModeChoice(mode: appModel.adDetectionSettings.mode)
        }
    }

    private var availableChoices: [ModeChoice] {
        appModel.remoteTranscriptionPurchases.isSurfaceVisible
            ? ModeChoice.allCases
            : [.ask, .onDevice]
    }
}
