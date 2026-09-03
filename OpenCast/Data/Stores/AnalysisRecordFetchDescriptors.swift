import SwiftData

/// The concrete fetch descriptors one analysis store hands its record set.
/// `#Predicate` cannot abstract over protocol key paths on `@Model` types,
/// so each store builds its own descriptors against its own record class.
struct AnalysisRecordFetchDescriptors<Record: PersistentModel>: Sendable {
    let all: @Sendable () -> FetchDescriptor<Record>
    let forEpisodeID: @Sendable (String) -> FetchDescriptor<Record>
    let forPodcastID: @Sendable (String) -> FetchDescriptor<Record>
}
