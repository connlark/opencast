import LinkPresentation
import UIKit
import UniformTypeIdentifiers

/// Shares the notes as a named text file, or as Markdown when the destination
/// is Apple Notes. UIKit can ask for the item on a background queue.
nonisolated final class EpisodeNotesActivityItem: NSObject, UIActivityItemSource {
    let export: EpisodeNotesShare

    init(export: EpisodeNotesShare) {
        self.export = export
    }

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
