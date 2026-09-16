/// One-time confirmation before the first Recap or Ask request, recorded like
/// the Chapters & Summary disclosure. The body states the whole data path so
/// the sheets never need to repeat it.
enum TranscriptIntelligenceDisclosureCopy {
    nonisolated static let title = "Use Apple Intelligence?"
    nonisolated static let confirmButtonTitle = "Continue"
    nonisolated static let body = "Passages from this episode’s transcript are sent to Apple’s Private Cloud Compute to answer. Apple does not store them. Your audio is never sent. Results stay on this device."
}
