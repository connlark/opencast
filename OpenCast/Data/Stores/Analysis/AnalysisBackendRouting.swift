/// Selects the build's normal routing or resolves through StoreKit explicitly.
/// The explicit path lets focused tests exercise release routing in Debug.
nonisolated enum AnalysisBackendRouting: Sendable, Equatable {
    case currentBuild
    case storeEnvironment
}
