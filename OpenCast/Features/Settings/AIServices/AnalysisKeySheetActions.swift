import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData

/// What the key sheet does to a saved key, and what that does to the tier
/// state: any change to the Google key here makes what Google said about the
/// last one stale, and a Test's answer lands only on the key it was given for.
struct AnalysisKeySheetActions {
    let provider: AnalysisProvider
    let keys: AnalysisProviderKeyStore
    let tier: AnalysisKeyTierStore
    let modelContext: ModelContext

    /// `tested` is the Test answer the sheet held before Save cleared it, so
    /// a paid key does not pay for a second check at its first run.
    func save(
        _ key: AnalysisProviderKey,
        syncs: Bool,
        tested: AnalysisKeyTierStore.Answer?
    ) throws(AnalysisProviderKeyStoreError) {
        do throws(AnalysisProviderKeyStoreError) {
            try keys.save(key, provider: provider, syncs: syncs)
        } catch {
            // This device's copy outlived a sync-on save and wins every read,
            // so only a read says whether the typed key is the one in use.
            if error.savedLocallyLeavingSyncedCopy(syncs: syncs)
                || (error.savedSyncedLeavingLocalCopy(syncs: syncs) && savedKeyDigest == key.digest) {
                noteKeyChanged(tested: tested)
            }
            throw error
        }
        noteKeyChanged(tested: tested)
    }

    /// Only sync-off resets: turning sync on keeps the same key in use, and
    /// a paid key must not pay for another check.
    func setSyncs(_ syncs: Bool, tested: AnalysisKeyTierStore.Answer?) throws(AnalysisProviderKeyStoreError) {
        do throws(AnalysisProviderKeyStoreError) {
            try keys.setSyncs(syncs, provider: provider)
        } catch {
            if error.savedLocallyLeavingSyncedCopy(syncs: syncs) {
                noteKeyChanged(tested: tested)
            }
            throw error
        }
        if !syncs {
            noteKeyChanged(tested: tested)
        }
    }

    func remove(includingSyncedCopy: Bool) throws(AnalysisProviderKeyStoreError) {
        try keys.remove(provider: provider, includingSyncedCopy: includingSyncedCopy)
        resetTier()
    }

    /// Reads the saved key now: the sheet's draft generation cannot see a key
    /// replaced through iCloud Keychain during the wait.
    func applyTierAnswer(_ answer: AnalysisKeyTierStore.Answer?) {
        guard provider == .google, let answer else {
            return
        }
        tier.apply(answer, savedKeyDigest: savedKeyDigest, modelContext: modelContext)
    }

    private var savedKeyDigest: Data? {
        (try? keys.key(for: provider))?.digest
    }

    private func noteKeyChanged(tested: AnalysisKeyTierStore.Answer?) {
        resetTier()
        applyTierAnswer(tested)
    }

    private func resetTier() {
        if provider == .google {
            tier.reset(modelContext: modelContext)
        }
    }
}
