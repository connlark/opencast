import Foundation
import Observation

@Observable
final class KnownPodcastsStore {
    struct Key: Hashable {
        let resultID: String?
        let feedURLs: Set<String>
    }

    private struct Adding {
        let key: Key
        var hasClaimedWrite = false
    }

    private var aliasGroups: [Set<String>] = []
    private var feedURLsByResultID: [String: Set<String>] = [:]
    private var addingByToken: [UUID: Adding] = [:]

    func feedURLs(for key: Key) -> Set<String> {
        var seed = key.feedURLs
        if let resultID = key.resultID {
            seed.formUnion(feedURLsByResultID[resultID] ?? [])
        }
        return aliasGroups.reduce(seed) { known, group in
            group.isDisjoint(with: seed) ? known : known.union(group)
        }
    }

    func libraryFeedURL(for key: Key, activePodcastIDs: Set<String>) -> String? {
        feedURLs(for: key).intersection(activePodcastIDs).min()
    }

    func learn(_ urls: Set<String>, about key: Key) {
        let known = feedURLs(for: Key(resultID: key.resultID, feedURLs: key.feedURLs.union(urls)))
        guard !known.isEmpty else {
            return
        }
        if let resultID = key.resultID, feedURLsByResultID[resultID] != known {
            feedURLsByResultID[resultID] = known
        }
        guard !aliasGroups.contains(known) else {
            return
        }
        aliasGroups.removeAll { !$0.isDisjoint(with: known) }
        aliasGroups.append(known)
    }

    func isAdding(_ key: Key) -> Bool {
        addingByToken.values.contains { isSameShow($0.key, key) }
    }

    func beginAdding(_ key: Key) -> UUID? {
        learn([], about: key)
        guard !isAdding(key) else {
            return nil
        }
        let token = UUID()
        addingByToken[token] = Adding(key: key)
        return token
    }

    /// Two adds of one show can both be under way when their overlap was learned after both began.
    /// Only one may write: the first to claim.
    func claimWrite(_ token: UUID) -> Bool {
        guard let adding = addingByToken[token] else {
            return false
        }
        let rivals = addingByToken.filter { $0.key != token && isSameShow($0.value.key, adding.key) }.values
        guard rivals.allSatisfy({ !$0.hasClaimedWrite }) else {
            return false
        }
        addingByToken[token]?.hasClaimedWrite = true
        return true
    }

    func finishAdding(_ token: UUID) {
        addingByToken[token] = nil
    }

    private func isSameShow(_ first: Key, _ second: Key) -> Bool {
        (first.resultID != nil && first.resultID == second.resultID)
            || !feedURLs(for: first).isDisjoint(with: feedURLs(for: second))
    }
}
