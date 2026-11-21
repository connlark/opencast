import OpenCastAnalysis

/// A bundle card with the label its model is offered under.
nonisolated struct AnalysisModelCardContent: Identifiable, Equatable {
    let id: AnalysisModelIdentity
    let title: String
    let providerName: String
    let price: String
    let strengths: [String]
    let weaknesses: [String]

    static func cards(in snapshot: AnalysisPolicySnapshot) -> [AnalysisModelCardContent] {
        snapshot.bundle.modelCards.compactMap { card in
            let entry = AnalysisFeature.allCases
                .flatMap { snapshot.modelEntries(for: $0, provider: card.provider) }
                .first { $0.modelID == card.modelID }
            return entry.map {
                AnalysisModelCardContent(
                    id: card.identity,
                    title: $0.label,
                    providerName: card.provider.displayName,
                    price: card.price,
                    strengths: card.strengths,
                    weaknesses: card.weaknesses
                )
            }
        }
    }
}
