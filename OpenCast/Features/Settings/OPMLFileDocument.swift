import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct OPMLFileDocument: FileDocument {
    nonisolated static let readableContentTypes: [UTType] = [.opml, .xml]
    nonisolated static let writableContentTypes: [UTType] = [.opml, .xml]

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    nonisolated static let opml =
        UTType("com.connor.opencast.opml")
        ?? UTType(filenameExtension: "opml", conformingTo: .xml)
        ?? .xml
}
