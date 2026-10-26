import OpenCastAnalysis

/// The networked layer of the analysis package: provider transports that map
/// the canonical analysis payload to a vendor wire request and conform to
/// ``AnalysisProviderTransport``, and ``AnalysisPolicyLoader``, which
/// downloads, verifies, caches and refreshes the signed policy bundle. The
/// `OpenCastAnalysis` library underneath does no networking and no file IO:
/// it holds the policy value types, the clamp, the signature verifier and the
/// baked bundle, and turns bytes into a validated bundle.
public enum OpenCastAnalysisProviders {}
