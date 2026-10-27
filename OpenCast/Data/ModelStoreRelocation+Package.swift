import Foundation

nonisolated extension ModelStoreRelocation {
    /// The store package at one URL, by the package rule: the main file, its
    /// `-wal`, `-shm` and `-journal`, and every directory beside it named
    /// `.<stem>_…` (Core Data's support directory) or `<stem>_…` (CloudKit
    /// mirroring's assets directory).
    nonisolated struct Package {
        nonisolated enum EntryName {
            case store
            case sidecar
            case companionCandidate
            /// Starts with the store's file name but is none of the four files.
            case unforeseen
            /// Not part of the package; never touched or judged.
            case outside
        }

        /// The entries beside the store, classified by name and by type.
        nonisolated struct Inventory {
            /// The `-wal`, `-shm` and `-journal` files present.
            var sidecars: [String] = []
            var companions: [String] = []
            /// Package-named entries of an unforeseen name or type.
            var unforeseen: [String] = []
        }

        let storeURL: URL
        let directory: URL
        let storeName: String
        private let stem: String

        init(storeURL: URL) {
            self.storeURL = storeURL
            directory = storeURL.deletingLastPathComponent()
            storeName = storeURL.lastPathComponent
            stem = storeURL.deletingPathExtension().lastPathComponent
        }

        var walName: String { storeName + "-wal" }
        var shmName: String { storeName + "-shm" }
        var journalName: String { storeName + "-journal" }
        var sidecarNames: [String] { [walName, shmName, journalName] }

        func url(_ entryName: String) -> URL {
            directory.appending(path: entryName, directoryHint: .notDirectory)
        }

        func classify(_ entryName: String) -> EntryName {
            if entryName == storeName {
                return .store
            }
            if sidecarNames.contains(entryName) {
                return .sidecar
            }
            if entryName.hasPrefix(storeName) {
                return .unforeseen
            }
            if entryName.hasPrefix(".\(stem)_") || entryName.hasPrefix("\(stem)_") {
                return .companionCandidate
            }
            return .outside
        }

        /// Every package entry beside the store except the main file, sorted.
        func packageEntryNames(operations: any ModelStoreFileOperations) throws -> [String] {
            try operations.entryNames(in: directory)
                .filter { name in
                    let kind = classify(name)
                    return kind != .outside && kind != .store
                }
                .sorted()
        }

        /// Sidecars must be files and companions directories; any other
        /// package-named entry is unforeseen. An entry that vanishes between
        /// the listing and its probe is skipped.
        func inventory(operations: any ModelStoreFileOperations) throws -> Inventory {
            var inventory = Inventory()
            for name in try operations.entryNames(in: directory).sorted() {
                let kind = classify(name)
                guard kind != .outside, kind != .store else {
                    continue
                }
                guard kind != .unforeseen else {
                    inventory.unforeseen.append(name)
                    continue
                }
                guard let status = try operations.status(at: url(name)) else {
                    continue
                }
                switch (kind, status.isDirectory) {
                case (.companionCandidate, true):
                    inventory.companions.append(name)
                case (.sidecar, false):
                    inventory.sidecars.append(name)
                default:
                    inventory.unforeseen.append(name)
                }
            }
            return inventory
        }
    }
}
