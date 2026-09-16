import SwiftData
import SwiftUI

/// Recap of the transcript window ending at the playhead captured when the
/// menu entry was tapped. Runs the eligibility gate, the one-time
/// disclosure, and one recap request; a tapped timestamp seeks playback and
/// dismisses.
struct TranscriptRecapSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let episodeID: String
    let kind: TranscriptRecapWindowKind
    let playhead: TimeInterval

    @State private var phase = TranscriptRecapSheetPhase.loading
    @State private var requestGeneration = 0
    @State private var document: EpisodeTranscriptDocument?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Recap")
                .navigationSubtitle(kind.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
        .task(id: requestGeneration) {
            await run()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Recapping \(kind.title.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disclosure:
            TranscriptIntelligenceDisclosureView(onContinue: acknowledgeDisclosure, onCancel: dismiss.callAsFunction)
        case .unavailable(let availability):
            TranscriptIntelligenceUnavailableView(
                availability: availability,
                offersLimitIncrease: appModel.transcriptIntelligence.quota.hasLimitIncreaseSuggestion,
                onRequestLimitIncrease: requestLimitIncrease
            )
        case .nothingToRecap(let kind):
            ContentUnavailableView {
                Label("Nothing to Recap Yet", systemImage: "text.page")
            } description: {
                Text(TranscriptRecapError.nothingToRecap(kind).errorDescription ?? "")
            }
        case .loaded(let result):
            recapList(result)
        case .failed(let failure):
            ContentUnavailableView {
                Label("Couldn’t Recap", systemImage: "exclamationmark.bubble")
            } description: {
                Text(failure.userMessage ?? "")
            } actions: {
                if Self.allowsRetry(after: failure) {
                    Button("Try Again", action: retry)
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func recapList(_ result: TranscriptRecapResult) -> some View {
        List {
            Section {
                ForEach(Array(result.bullets.enumerated()), id: \.offset) { _, bullet in
                    TranscriptRecapBulletRow(bullet: bullet) {
                        seek(to: bullet)
                    }
                }
            } header: {
                Text("\(result.windowStart.formattedPlaybackDuration) – \(result.windowEnd.formattedPlaybackDuration)")
                    .monospacedDigit()
            } footer: {
                Label("Generated with Apple Intelligence. Tap a time to jump there.", systemImage: "apple.intelligence")
            }
        }
        .accessibilityIdentifier("Transcript Recap List")
    }

    // MARK: - Request

    private func run() async {
        let store = appModel.transcriptIntelligence
        store.refreshAvailability()
        guard store.availability == .available else {
            phase = .unavailable(store.availability)
            return
        }
        guard store.hasAcknowledgedDisclosure else {
            phase = .disclosure
            return
        }
        phase = .loading
        do {
            let document = try await loadDocument()
            let result = try await TranscriptRecapGenerator(store: store).recap(
                document: document,
                kind: kind,
                playhead: playhead
            )
            phase = .loaded(result)
        } catch is CancellationError {
        } catch TranscriptRecapError.nothingToRecap(let kind) {
            phase = .nothingToRecap(kind)
        } catch let failure as TranscriptIntelligenceFailure {
            guard failure != .cancelled, !Task.isCancelled else {
                return
            }
            // Rate limits and entitlement failures move the store into a
            // persistent state; the calm state view explains those better
            // than a per-request message.
            phase = store.availability == .available ? .failed(failure) : .unavailable(store.availability)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            phase = .failed(.unknown(error.localizedDescription))
        }
    }

    private func loadDocument() async throws -> EpisodeTranscriptDocument {
        if let document {
            return document
        }
        let loaded = try await appModel.transcriptions.loadDocument(for: episodeID)
        document = loaded
        return loaded
    }

    private func acknowledgeDisclosure() {
        appModel.transcriptIntelligence.acknowledgeDisclosure(modelContext: modelContext)
        retry()
    }

    private func retry() {
        requestGeneration += 1
    }

    private func requestLimitIncrease() {
        appModel.transcriptIntelligence.showQuotaLimitIncreaseSuggestion()
    }

    /// Guardrail and refusal outcomes never retry: the same window gets the
    /// same answer, and the plan's response is a different window.
    private static func allowsRetry(after failure: TranscriptIntelligenceFailure) -> Bool {
        switch failure {
        case .guardrailViolation, .refusal, .unsupportedLanguage, .notEntitled, .cancelled:
            false
        case .rateLimited, .quotaLimitReached, .contextSizeExceeded, .offline, .serviceUnavailable,
             .timeout, .malformedOutput, .unknown:
            true
        }
    }

    // MARK: - Seek

    private func seek(to bullet: TranscriptRecapResultBullet) {
        TranscriptCitationSeeker.seek(
            to: bullet.start,
            episodeID: episodeID,
            document: document,
            appModel: appModel,
            modelContext: modelContext
        )
        dismiss()
    }
}
