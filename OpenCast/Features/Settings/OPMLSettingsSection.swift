import Foundation
import OpenCastCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct OPMLSettingsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var importFlow = OPMLImportFlow()
    @State private var isShowingExporter = false
    @State private var exportDocument = OPMLFileDocument()
    @State private var exportStatusMessage: String?
    @State private var exportErrorMessage: String?

    var body: some View {
        Section {
            OPMLImportStateView(
                state: importFlow.state,
                showsImportButtonAfterSuccess: true,
                importAction: showImporter
            )

            Button(
                "Export Subscriptions",
                systemImage: "square.and.arrow.up",
                action: exportSubscriptions
            )
            .disabled(importFlow.state.isImporting)

            if let exportStatusMessage {
                Label(exportStatusMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            if let exportErrorMessage {
                Label(exportErrorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Import & Export")
        } footer: {
            Text(OPMLImportCopy.subscriptionsOnlyFooter)
        }
        .fileImporter(
            isPresented: $importFlow.isShowingImporter,
            allowedContentTypes: OPMLFileDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: .opml,
            defaultFilename: OPMLExporter.defaultFilename,
            onCompletion: handleExportResult
        )
        .onDisappear {
            importFlow.cancelImportTask()
        }
    }

    private func showImporter() {
        exportStatusMessage = nil
        exportErrorMessage = nil
        importFlow.showImporter()
    }

    private func exportSubscriptions() {
        exportStatusMessage = nil
        exportErrorMessage = nil

        do {
            let references = OPMLExportBuilder.feedReferences(from: appModel.library.subscriptions)
            guard !references.isEmpty else {
                exportErrorMessage = "There are no active subscriptions to export."
                return
            }

            let data = try OPMLExporter().export(feedReferences: references)
            exportDocument = OPMLFileDocument(data: data)
            isShowingExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        importFlow.handleImportResult(
            result,
            libraryStore: appModel.library,
            modelContext: modelContext,
            onImportStart: clearExportMessages
        )
    }

    private func handleExportResult(_ result: Result<URL, any Error>) {
        switch result {
        case .success:
            exportStatusMessage = "Subscriptions exported."
        case .failure(let error):
            exportErrorMessage = error.localizedDescription
        }
    }

    private func clearExportMessages() {
        exportStatusMessage = nil
        exportErrorMessage = nil
    }
}
