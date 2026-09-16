import SwiftData
import SwiftUI

/// Question-and-answer over one episode's transcript. Runs the eligibility
/// gate, the one-time disclosure, builds the passage index, then keeps one
/// in-memory conversation for the sheet's lifetime; a tapped citation seeks
/// playback and dismisses.
struct TranscriptAskSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let episodeID: String

    @State private var phase = TranscriptAskSheetPhase.loading
    @State private var setupGeneration = 0
    @State private var document: EpisodeTranscriptDocument?
    @State private var session: TranscriptAskSession?
    @State private var messages: [TranscriptAskMessage] = []
    @State private var draft = ""
    @State private var pendingQuestion: TranscriptAskPendingQuestion?
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ask")
                .navigationSubtitle("About This Episode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
        .task(id: setupGeneration) {
            await prepare()
        }
        .task(id: pendingQuestion?.id) {
            await respondToPendingQuestion()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Preparing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disclosure:
            TranscriptIntelligenceDisclosureView(onContinue: acknowledgeDisclosure, onCancel: dismiss.callAsFunction)
        case .unavailable(let availability):
            TranscriptIntelligenceUnavailableView(
                availability: availability,
                featureName: "Ask",
                offersLimitIncrease: appModel.transcriptIntelligence.quota.hasLimitIncreaseSuggestion,
                onRequestLimitIncrease: requestLimitIncrease
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Transcript", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retrySetup)
                    .buttonStyle(.glassProminent)
            }
        case .ready:
            conversation
        }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty {
                    TranscriptAskIntroView(onSuggestion: ask)
                }
                ForEach(messages) { message in
                    TranscriptAskMessageRow(message: message, onSeek: seek)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(messages.isEmpty ? .top : .bottom)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("Transcript Ask Messages")
        .safeAreaInset(edge: .bottom) {
            TranscriptAskComposer(
                draft: $draft,
                isResponding: isResponding,
                isFocused: $isComposerFocused,
                onSend: sendDraft
            )
        }
    }

    private var isResponding: Bool {
        messages.last?.isStreaming == true
    }

    // MARK: - Setup

    private func prepare() async {
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
        if session == nil {
            phase = .loading
            do {
                let document = try await loadDocument()
                let index = try await TranscriptPassageIndex.build(segments: document.segments)
                try Task.checkCancellation()
                session = TranscriptAskSession(store: store, document: document, index: index)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                phase = .failed(error.localizedDescription)
                return
            }
        }
        phase = .ready
        isComposerFocused = true
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
        retrySetup()
    }

    private func retrySetup() {
        setupGeneration += 1
    }

    private func requestLimitIncrease() {
        appModel.transcriptIntelligence.showQuotaLimitIncreaseSuggestion()
    }

    // MARK: - Turns

    private func sendDraft() {
        ask(draft)
    }

    private func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding, session != nil else {
            return
        }
        draft = ""
        messages.append(TranscriptAskMessage(content: .question(trimmed)))
        messages.append(TranscriptAskMessage(content: .streaming("")))
        pendingQuestion = TranscriptAskPendingQuestion(text: trimmed)
    }

    private func respondToPendingQuestion() async {
        guard let pendingQuestion, let session,
              let messageID = messages.last(where: \.isStreaming)?.id
        else {
            return
        }
        do {
            let answer = try await session.ask(pendingQuestion.text) { partial in
                update(messageID, to: .streaming(partial))
            }
            update(messageID, to: .answer(answer))
        } catch let failure as TranscriptIntelligenceFailure {
            guard failure != .cancelled, !Task.isCancelled else {
                return
            }
            update(messageID, to: .failure(failure))
        } catch {
            guard !Task.isCancelled else {
                return
            }
            update(messageID, to: .failure(.unknown(error.localizedDescription)))
        }
    }

    private func update(_ messageID: UUID, to content: TranscriptAskMessage.Content) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].content = content
    }

    // MARK: - Seek

    private func seek(to citation: TranscriptAskCitation) {
        TranscriptCitationSeeker.seek(
            to: citation.start,
            episodeID: episodeID,
            document: document,
            appModel: appModel,
            modelContext: modelContext
        )
        dismiss()
    }
}
