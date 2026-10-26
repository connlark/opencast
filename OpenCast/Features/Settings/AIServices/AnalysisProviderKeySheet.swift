import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftUI

/// Adds, tests, re-syncs or removes one provider's key. The typed key lives
/// only in the field's state: it is turned into an `AnalysisProviderKey`
/// inside Test and Save, and cleared after Save and on dismissal. A test
/// never changes what is stored.
struct AnalysisProviderKeySheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let provider: AnalysisProvider

    @State private var draft = AnalysisKeyDraft()
    @State private var syncs = true
    /// Bumped by every edit, sync change, Save and Remove. A test result
    /// stamped with an older generation describes a draft that is gone.
    @State private var draftGeneration = 0
    @State private var testTask: Task<Void, Never>?
    @State private var isTesting = false
    @State private var testResult: AnalysisKeyTestResult?
    @State private var errorMessage: String?
    @State private var isConfirmingRemove = false
    /// What the confirmation said, so Remove deletes exactly that: a synced
    /// copy that arrives while the dialog is open is not part of it. Unless
    /// the synced copy is known to be absent, Remove includes it.
    @State private var removalScope = AnalysisSyncedCopyStatus.absent
    @State private var isConfirmingSyncedCopyRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                keySection
                syncSection
                actionsSection
                if presence.isSaved {
                    removeSection
                }
            }
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AIServicesCopy.cancel, action: dismiss.callAsFunction)
                        .accessibilityIdentifier("AI Services Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AIServicesCopy.save, action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("AI Services Save Key")
                }
            }
        }
        .onAppear(perform: loadSyncChoice)
        .onDisappear(perform: discardDraft)
        .onChange(of: draft) { _, _ in
            invalidateTestResult()
        }
        .onChange(of: syncs) { _, _ in
            invalidateTestResult()
        }
    }

    // MARK: Sections

    private var keySection: some View {
        Section {
            SecureField(
                AIServicesCopy.keyFieldLabel(provider),
                text: $draft.text,
                prompt: Text(AIServicesCopy.fieldPrompt)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(AIServicesCopy.keyFieldLabel(provider))
            .accessibilityIdentifier("AI Services Key Field")

            PasteButton(payloadType: String.self, onPaste: pasteKey)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            AnalysisKeyTestStatusLabel(
                provider: provider,
                isTesting: isTesting,
                result: testResult,
                showsImplausibleWarning: hasDraft && !isDraftPlausible
            )
        }
    }

    private var syncSection: some View {
        Section {
            Toggle(AIServicesCopy.syncToggle, isOn: $syncs)
                .accessibilityIdentifier("AI Services Sync Toggle")

            if appModel.analysisKeys.syncedCopyBesideLocalKey(for: provider) {
                Button(action: confirmSyncedCopyRemoval) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AIServicesCopy.removeSyncedCopy)
                        Text(AIServicesCopy.syncedCopyAlsoElsewhere)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .accessibilityHint(AIServicesCopy.removeSyncedCopyHint)
                .accessibilityIdentifier("AI Services Remove Synced Copy")
                .confirmationDialog(
                    AIServicesCopy.removeSyncedCopyTitle,
                    isPresented: $isConfirmingSyncedCopyRemoval,
                    titleVisibility: .visible
                ) {
                    Button(AIServicesCopy.removeSyncedCopy, role: .destructive, action: removeSyncedCopy)
                    Button(AIServicesCopy.cancel, role: .cancel) {}
                } message: {
                    Text(AIServicesCopy.removeSyncedCopyMessage)
                }
            }
        } footer: {
            Text(AIServicesCopy.syncFooter)
        }
    }

    private var actionsSection: some View {
        Section {
            Button(AIServicesCopy.test, systemImage: "checkmark.shield", action: testKey)
                .disabled(!canTest)
                .accessibilityHint(AIServicesCopy.testHint(provider))
                .accessibilityIdentifier("AI Services Test Key")

            if keyURL != nil {
                Button(AIServicesCopy.getKey(provider), systemImage: "arrow.up.forward.app", action: openKeyPage)
                    .accessibilityHint(AIServicesCopy.getKeyHint(provider))
                    .accessibilityIdentifier("AI Services Get Key")
            }
        }
    }

    private var removeSection: some View {
        Section {
            Button(AIServicesCopy.removeKey, systemImage: "trash", role: .destructive, action: confirmRemove)
                .accessibilityIdentifier("AI Services Remove Key")
                .confirmationDialog(
                    AIServicesCopy.removeTitle(provider),
                    isPresented: $isConfirmingRemove,
                    titleVisibility: .visible
                ) {
                    Button(AIServicesCopy.removeKey, role: .destructive, action: remove)
                    Button(AIServicesCopy.cancel, role: .cancel) {}
                } message: {
                    Text(AIServicesCopy.removeMessage(syncedCopy: removalScope))
                }
        }
    }

    // MARK: State

    private var presence: AnalysisKeyPresence {
        appModel.analysisKeys.presence(for: provider)
    }

    private var savedSyncs: Bool? {
        if case .saved(let synced) = presence {
            synced
        } else {
            nil
        }
    }

    private var keyURL: URL? {
        appModel.analysisPolicy.snapshot.bundle.providers[provider]?.keyURL
    }

    private var hasDraft: Bool {
        draft.text.contains { !$0.isWhitespace }
    }

    private var isDraftPlausible: Bool {
        AnalysisProviderKeyFormat.isPlausible(draft.text)
    }

    /// A whole typed key, or (with the field empty) a changed sync choice
    /// for the saved key.
    private var canSave: Bool {
        if hasDraft {
            return isDraftPlausible
        }
        guard let savedSyncs else {
            return false
        }
        return syncs != savedSyncs
    }

    private var testSubject: AnalysisKeyTestSubject {
        AnalysisKeyTestSubject.choose(draft: draft.text, hasSavedKey: presence.isSaved)
    }

    private var canTest: Bool {
        !isTesting && testSubject != .none
    }

    // MARK: Actions

    private func loadSyncChoice() {
        syncs = savedSyncs ?? true
    }

    private func pasteKey(_ pastedStrings: [String]) {
        guard let pasted = pastedStrings.first else {
            return
        }
        draft.text = pasted
    }

    private func testKey() {
        errorMessage = nil
        let key: AnalysisProviderKey?
        switch testSubject {
        case .typed:
            key = AnalysisProviderKey(draft.text)
        case .saved:
            key = try? appModel.analysisKeys.key(for: provider)
        case .none:
            return
        }
        guard let key else {
            testResult = .failed(.requestRejected)
            return
        }

        invalidateTestResult()
        let generation = draftGeneration
        let tester = appModel.analysisKeyTester
        let snapshot = appModel.analysisPolicy.snapshot
        let provider = provider
        isTesting = true
        testTask = Task {
            let result = await tester.test(key, provider: provider, snapshot: snapshot)
            guard !Task.isCancelled, generation == draftGeneration else {
                return
            }
            testResult = result
            isTesting = false
            testTask = nil
        }
    }

    private func save() {
        errorMessage = nil
        invalidateTestResult()
        if hasDraft {
            guard isDraftPlausible, let key = AnalysisProviderKey(draft.text) else {
                return
            }
            do throws(AnalysisProviderKeyStoreError) {
                try appModel.analysisKeys.save(key, provider: provider, syncs: syncs)
            } catch {
                showSaveFailure(error)
                return
            }
        } else if let savedSyncs, syncs != savedSyncs {
            do throws(AnalysisProviderKeyStoreError) {
                try appModel.analysisKeys.setSyncs(syncs, provider: provider)
            } catch {
                showSaveFailure(error)
                return
            }
        } else {
            return
        }
        draft = AnalysisKeyDraft()
        dismiss()
    }

    /// Only this call's failure decides: a save with sync off that wrote the
    /// key and failed at deleting the synced copy saved it here, so the
    /// typed key goes and the sheet says what remains; any other failure
    /// saved nothing, so the typed key stays.
    private func showSaveFailure(_ error: AnalysisProviderKeyStoreError) {
        if error.savedLocallyLeavingSyncedCopy(syncs: syncs) {
            errorMessage = AIServicesCopy.syncOffIncomplete
            draft = AnalysisKeyDraft()
        } else {
            errorMessage = AIServicesCopy.saveFailed
        }
    }

    private func confirmSyncedCopyRemoval() {
        isConfirmingSyncedCopyRemoval = true
    }

    private func removeSyncedCopy() {
        errorMessage = nil
        do {
            try appModel.analysisKeys.removeSyncedCopy(provider: provider)
        } catch {
            errorMessage = AIServicesCopy.syncedCopyRemovalFailed
        }
    }

    private func confirmRemove() {
        removalScope = appModel.analysisKeys.removalScope(for: provider)
        isConfirmingRemove = true
    }

    private func remove() {
        errorMessage = nil
        invalidateTestResult()
        do {
            try appModel.analysisKeys.remove(provider: provider, includingSyncedCopy: removalScope != .absent)
        } catch {
            errorMessage = AIServicesCopy.removeFailed
            return
        }
        appModel.cancelAnalysisRuns(onProvider: provider)
        draft = AnalysisKeyDraft()
        dismiss()
    }

    private func openKeyPage() {
        guard let keyURL else {
            return
        }
        openURL(keyURL)
    }

    private func invalidateTestResult() {
        draftGeneration += 1
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testResult = nil
    }

    private func discardDraft() {
        invalidateTestResult()
        draft = AnalysisKeyDraft()
    }
}

#Preview("New Key") {
    Text("AI Services")
        .sheet(isPresented: .constant(true)) {
            AnalysisProviderKeySheet(provider: .google)
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.dark)
}

#Preview("Saved Key") {
    @Previewable @State var appModel = AIServicesPreviewSamples.appModel(savedProviders: [.openai: false])

    Text("AI Services")
        .sheet(isPresented: .constant(true)) {
            AnalysisProviderKeySheet(provider: .openai)
        }
        .environment(appModel)
        .task {
            await appModel.analysisKeys.refreshPresences()
        }
        .preferredColorScheme(.light)
}
