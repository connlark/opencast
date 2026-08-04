import SwiftUI

struct EpisodeTranscriptMenu: View {
    @Binding var showsTimestamps: Bool
    let plainTextExport: String
    let timestampedTextExport: String
    let adAnalysisState: EpisodeAdAnalysisJobState
    let canAnalyze: Bool
    let canImproveTranscript: Bool
    let onAnalyzeAds: () -> Void
    let onDeleteAdAnalysis: () -> Void
    let onImproveTranscript: () -> Void
    let onDeleteTranscript: () -> Void

    @State private var isConfirmingDelete = false
    @State private var isConfirmingImprove = false

    var body: some View {
        Menu {
            Toggle("Show Timestamps", systemImage: "clock", isOn: $showsTimestamps)

            Section {
                ShareLink(item: plainTextExport) {
                    Label("Share Transcript", systemImage: "square.and.arrow.up")
                }
                ShareLink(item: timestampedTextExport) {
                    Label("Share with Timestamps", systemImage: "square.and.arrow.up.on.square")
                }
            }

            Section {
                adAnalysisActions
            }

            Section {
                if canImproveTranscript {
                    Button("Improve Transcript", systemImage: "sparkles", action: confirmImprove)
                }
                Button("Delete Transcript", systemImage: "trash", role: .destructive, action: confirmDelete)
            }
        } label: {
            Label("Transcript Options", systemImage: "ellipsis.circle")
        }
        .confirmationDialog(
            "Delete Transcript?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Transcript", role: .destructive, action: onDeleteTranscript)
        } message: {
            Text("This also deletes the promo/ad analysis for this episode.")
        }
        .confirmationDialog(
            "Improve Transcript with Apple Speech?",
            isPresented: $isConfirmingImprove,
            titleVisibility: .visible
        ) {
            Button("Improve Transcript", action: onImproveTranscript)
        } message: {
            Text("This re-transcribes the episode with Apple Speech for better accuracy. Keep OpenCast open while it runs — improving works only in the foreground and starts over if the app is closed or backgrounded. Your current transcript stays until the improved one is ready.")
        }
    }

    @ViewBuilder
    private var adAnalysisActions: some View {
        switch adAnalysisState {
        case .unavailable:
            Button("Analyze Promos & Ads", systemImage: "megaphone", action: onAnalyzeAds)
                .disabled(true)
        case .ready:
            Button("Analyze Promos & Ads", systemImage: "megaphone", action: onAnalyzeAds)
                .disabled(!canAnalyze)
        case .running:
            Button("Analyzing Promos & Ads…", systemImage: "megaphone", action: onAnalyzeAds)
                .disabled(true)
        case .completed(_, let isStale):
            if canAnalyze {
                Button(
                    isStale ? "Analyze Promos & Ads" : "Reanalyze Promos & Ads",
                    systemImage: "arrow.clockwise",
                    action: onAnalyzeAds
                )
            }
            Button("Delete Promo/Ad Analysis", systemImage: "trash", role: .destructive, action: onDeleteAdAnalysis)
        case .failed:
            if canAnalyze {
                Button("Retry Promo/Ad Analysis", systemImage: "arrow.clockwise", action: onAnalyzeAds)
            }
            Button("Delete Promo/Ad Analysis", systemImage: "trash", role: .destructive, action: onDeleteAdAnalysis)
        }
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func confirmImprove() {
        isConfirmingImprove = true
    }
}
