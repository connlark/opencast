/// A check a direct transport runs after its key's pacer admits a send and
/// immediately before the send leaves. A classification refuses the send:
/// nothing reaches the provider, the pacer's slot is freed, and the send is
/// recorded with the classification's listener failure. `nil` lets it go.
/// The app uses it to stop a send whose key was removed or replaced while
/// the send waited for the pacer.
public typealias AnalysisPreDispatchCheck = @Sendable () async -> AnalysisProviderErrorClassification?
