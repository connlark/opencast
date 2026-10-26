import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Every string the AI Services screens, the key notice and the key screen
/// show, so the copy can be reviewed in one place.
nonisolated enum AIServicesCopy {
    static let screenTitle = "AI Services"

    // MARK: Providers and features

    static func displayName(_ provider: AnalysisProvider) -> String {
        switch provider {
        case .google: "Google Gemini"
        case .openai: "OpenAI"
        }
    }

    static func shortName(_ provider: AnalysisProvider) -> String {
        switch provider {
        case .google: "Google"
        case .openai: "OpenAI"
        }
    }

    static func featureName(_ feature: AnalysisFeature) -> String {
        switch feature {
        case .adDetection: "Ad detection"
        case .chaptersSummary: "Chapters & Summary"
        }
    }

    // MARK: Notice

    static let noticeTitle = "Ad detection and Chapters & Summary are moving to your own key"
    static let noticeAddKey = "Add a key"
    static let noticeLater = "Later"

    static func noticeFirstParagraph(date: String) -> String {
        "From \(date), these two features use an API key from Google or OpenAI that you add in Settings. Your transcripts go straight from your device to the provider you choose; opencast is no longer in the middle."
    }

    static func noticeSecondParagraph(date: String, units: Int) -> String {
        "Until then nothing changes. After \(date), every install keeps \(units.formatted()) free analyses, then asks for a key. A Gemini key is free to create."
    }

    static func noticeRowBeforeTrial(date: String, units: Int) -> String {
        "Moving to your own key on \(date) · \(units.formatted()) free analyses remain"
    }

    static func noticeRowUnitsLeft(_ units: Int) -> String {
        "\(units.formatted()) free analyses remain"
    }

    static let noticeRowExhausted = "Your free analyses are used"

    /// The trial start as a calendar day in UTC: midnight UTC on 1 January
    /// must not read as 31 December west of Greenwich.
    static func trialDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    // MARK: Screen

    static let keysHeader = "API Keys"
    static let providerHeader = "Provider"
    static let usageHeader = "Usage"
    static let providersFooter = "Ad detection and Chapters & Summary run on your device and call the provider you choose with your own key. Recap and Ask use Apple's Private Cloud Compute and need no key."
    static let geminiPrivacyFootnote = "Google's free tier may use prompts to improve its products. With a paid Gemini key, Google doesn't use your prompts or responses to improve its products. See Google's terms."
    static let noKey = "No key"
    static let keySaved = "Key saved"
    /// The provider row when the last Keychain read failed.
    static let statusUnavailable = "Key status unavailable"

    static func status(_ presence: AnalysisKeyPresence) -> String {
        switch presence {
        case .none: noKey
        case .saved(synced: true): "Key saved · synced"
        case .saved(synced: false): "Key saved · this device"
        }
    }

    static func hubValue(hasSavedKey: Bool) -> String {
        hasSavedKey ? keySaved : noKey
    }

    // MARK: Usage

    static let usageFooter = "Usage is counted on your device from provider responses. Your provider's dashboard is the bill."
    static let usageEmpty = "No runs yet"

    static func usageLastRun(inputTokens: Int, outputTokens: Int, date: Date) -> String {
        "Last run: \(inputTokens.formatted()) in · \(outputTokens.formatted()) out · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func usageMonth(inputTokens: Int, outputTokens: Int) -> String {
        "This month: \(inputTokens.formatted()) in · \(outputTokens.formatted()) out"
    }

    // MARK: Key sheet

    static let test = "Test"
    static let save = "Save"
    static let cancel = "Cancel"
    static let syncToggle = "Sync with iCloud Keychain"
    static let removeKey = "Remove Key"
    static let fieldPrompt = "Paste your API key"
    static let testing = "Testing…"
    static let implausibleKey = "This doesn't look like an API key. Paste the whole key."
    static let syncFooter = "A synced key is available on your devices that use iCloud Keychain. Turning sync off keeps it on this device only and removes the synced copy from your other devices."
    static let saveFailed = "The key couldn't be saved. Try again."
    static let removeFailed = "The key couldn't be removed. Try again."
    /// Turning sync off kept the key here but could not delete the synced copy.
    static let syncOffIncomplete = "The key is saved on this device, but the synced copy couldn't be removed from your other devices."
    /// This device uses its local key and a synced copy is stored too.
    static let syncedCopyAlsoElsewhere = "A synced copy is also on your other devices"
    static let removeSyncedCopy = "Remove synced copy"
    static let removeSyncedCopyTitle = "Remove the synced copy?"
    static let removeSyncedCopyMessage = "It is removed from your other devices that use iCloud Keychain. This device keeps its key."
    static let syncedCopyRemovalFailed = "The synced copy couldn't be removed. Try again."

    static func getKey(_ provider: AnalysisProvider) -> String {
        "Get a key from \(shortName(provider))"
    }

    static func removeTitle(_ provider: AnalysisProvider) -> String {
        "Remove the \(shortName(provider)) key?"
    }

    /// What Remove deletes: the synced copy too unless it is known to be
    /// absent ("any synced copy" when unknown).
    static func removeMessage(syncedCopy: AnalysisSyncedCopyStatus) -> String {
        switch syncedCopy {
        case .present:
            "The key is removed from this device, and the synced key from your other devices that use iCloud Keychain."
        case .unknown:
            "The key is removed from this device, and any synced copy from your other devices that use iCloud Keychain."
        case .absent:
            "The key is removed from this device."
        }
    }

    static func testResult(_ result: AnalysisKeyTestResult, provider: AnalysisProvider) -> String {
        let name = shortName(provider)
        switch result {
        case .accepted:
            return "Key works"
        case .failed(let failure):
            switch failure {
            case .invalidKey:
                return "Key not accepted"
            case .billingOrQuota:
                return "Your \(name) account needs billing or quota enabled"
            case .rateLimited, .dailyLimit, .overloaded:
                return "Key accepted, but \(name) is busy or at its limit right now"
            case .timeout, .unreachable:
                return "Couldn't reach \(name). Check your connection and try again"
            case .modelUnavailable, .requestRejected, .malformedAnswer,
                 .trialExhausted, .trialRunBound, .trialPaused, .trialUnavailable, .keyRequired:
                return "Couldn't verify the key with \(name)"
            }
        }
    }

    // MARK: Key screen

    static let keyRequiredOpenSettings = "Open Settings"
    static let keyRequiredNotNow = "Not now"

    static func keyRequiredTitle(_ status: AnalysisTrialStatus) -> String {
        switch status {
        case .exhausted: "Add a key to keep going"
        case .notStarted, .unitsLeft: "Add your own key"
        }
    }

    static func keyRequiredBody(_ status: AnalysisTrialStatus, trialDate: String, lifetimeUnits: Int) -> String {
        switch status {
        case .exhausted:
            "Your \(lifetimeUnits.formatted()) free analyses are used. Add a Gemini or OpenAI key in Settings to run ad detection and Chapters & Summary on your own account."
        case .unitsLeft(let units):
            "You have \(units.formatted()) free analyses left. Add a Gemini or OpenAI key in Settings to run ad detection and Chapters & Summary on your own account."
        case .notStarted:
            "Until \(trialDate), ad detection and Chapters & Summary work without a key. After that, every install keeps \(lifetimeUnits.formatted()) free analyses, then asks for a key."
        }
    }

    // MARK: Accessibility

    static func statusAccessibilityValue(_ presence: AnalysisKeyPresence) -> String {
        switch presence {
        case .none: noKey
        case .saved(synced: true): "Key saved, synced"
        case .saved(synced: false): "Key saved, this device only"
        }
    }

    static func providerRowHint(_ provider: AnalysisProvider) -> String {
        "Opens the \(shortName(provider)) key"
    }

    static func keyFieldLabel(_ provider: AnalysisProvider) -> String {
        "\(displayName(provider)) API key"
    }

    static func testHint(_ provider: AnalysisProvider) -> String {
        "Checks the key with \(shortName(provider)) without running an analysis"
    }

    static func getKeyHint(_ provider: AnalysisProvider) -> String {
        "Opens \(shortName(provider))'s key page in your browser"
    }

    static let removeSyncedCopyHint = "Removes the synced copy from your other devices and keeps the key on this device"

    static func pickerLabel(_ feature: AnalysisFeature) -> String {
        "\(featureName(feature)) provider"
    }
}
