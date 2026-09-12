import Foundation
import Observation
import SwiftData

@Observable
final class OPMLImportFlow {
    private let importStore = OPMLImportStore()

    var isShowingImporter = false

    @ObservationIgnored private var importTask: Task<Void, Never>?

    var state: OPMLImportState {
        importStore.state
    }

    deinit {
        importTask?.cancel()
    }

    func showImporter() {
        isShowingImporter = true
    }

    func reportFailure(_ message: String) {
        importStore.reportFailure(message)
    }

    func handleImportResult(
        _ result: Result<[URL], any Error>,
        libraryStore: LibraryStore,
        modelContext: ModelContext,
        onImportStart: (() -> Void)? = nil
    ) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                reportFailure("No OPML file was selected.")
                return
            }

            importSubscriptions(
                from: url,
                libraryStore: libraryStore,
                modelContext: modelContext,
                onImportStart: onImportStart
            )
        case .failure(let error):
            reportFailure(error.localizedDescription)
        }
    }

    func importSubscriptions(
        from url: URL,
        libraryStore: LibraryStore,
        modelContext: ModelContext,
        onImportStart: (() -> Void)? = nil
    ) {
        importTask?.cancel()
        onImportStart?()

        importTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.importStore.importOPML(
                from: url,
                libraryStore: libraryStore,
                modelContext: modelContext
            )
            self.importTask = nil
        }
    }

    func cancelImportTask() {
        importTask?.cancel()
        importTask = nil
    }
}
