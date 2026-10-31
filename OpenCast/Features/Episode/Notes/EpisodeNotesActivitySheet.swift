import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

struct EpisodeNotesActivitySheet: UIViewControllerRepresentable {
    let export: EpisodeNotesShare

    func makeCoordinator() -> Coordinator { Coordinator(export: export) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [context.coordinator], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) {
        // Activity providers may request the files asynchronously while the sheet is alive.
        coordinator.export.removeFiles()
    }

    // UIKit can request the share item on a background queue.
    nonisolated final class Coordinator: NSObject, UIActivityItemSource {
        let export: EpisodeNotesShare

        init(export: EpisodeNotesShare) { self.export = export }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
            export.textURL
        }

        func activityViewController(_ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
            export.file(for: activityType?.rawValue)
        }

        func activityViewController(_ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
            export.title
        }

        func activityViewController(_ controller: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
            let file = export.file(for: activityType?.rawValue)
            return UTType(filenameExtension: file.pathExtension)?.identifier ?? UTType.plainText.identifier
        }

        func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
            let metadata = LPLinkMetadata()
            metadata.title = export.title
            return metadata
        }
    }
}
