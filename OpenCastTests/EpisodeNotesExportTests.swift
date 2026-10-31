import Foundation
import Testing
@testable import OpenCast

@MainActor
struct EpisodeNotesExportTests {
    @Test("Export contains title, show, whole-episode text, then notes in timestamp order")
    func exportOrder() {
        let whole = EpisodeNoteRecord(episodeID: "a", timestamp: 0, text: "Overall thoughts\nSecond line")
        whole.isEpisodeWide = true
        let later = EpisodeNoteRecord(episodeID: "a", timestamp: 125, text: "Later")
        let earlier = EpisodeNoteRecord(episodeID: "a", timestamp: 10, text: "Earlier")
        #expect(EpisodeNotesExport.text(episodeTitle: "Episode Title", showTitle: "Show Name", notes: [later, whole, earlier]) == "Episode Title\nShow Name\n\nPrivate Notes from opencast:\n\nOverall thoughts\nSecond line\n\n0:10\nEarlier\n\n2:05\nLater")
    }

    @Test("Timestamp-only exports omit an empty whole-episode section")
    func timestampOnly() {
        let note = EpisodeNoteRecord(episodeID: "a", timestamp: 0, text: "Beginning")
        #expect(EpisodeNotesExport.text(episodeTitle: "Episode", showTitle: "Show", notes: [note]) == "Episode\nShow\n\nPrivate Notes from opencast:\n\n0:00\nBeginning")
        #expect(EpisodeNotesExport.text(episodeTitle: "Episode", showTitle: "Show", notes: []) == "Episode\nShow\n\nPrivate Notes from opencast:")
    }

    @Test("Notes Markdown uses headings and preserves literal user text")
    func markdown() {
        let note = EpisodeNoteRecord(episodeID: "a", timestamp: 10, text: "# Literal *text*\n[link](url)")
        #expect(EpisodeNotesExport.markdown(episodeTitle: "A *title*", showTitle: "Show", notes: [note]) == "# A \\*title\\*\n## Show\n\n*Private Notes from opencast:*\n\n0:10  \n\\# Literal \\*text\\*  \n\\[link\\]\\(url\\)")
    }

    @Test("AirDrop gets a named UTF-8 txt file; Notes gets Markdown; temporary files are removed")
    func shareFiles() throws {
        let note = EpisodeNoteRecord(episodeID: "a", timestamp: 0, text: "Thought 📝")
        let export = try EpisodeNotesShare(episodeTitle: "Episode/Title", showTitle: "Show", notes: [note])
        defer { export.removeFiles() }
        let airDrop = export.file(for: "com.apple.UIKit.activity.AirDrop")
        #expect(airDrop.lastPathComponent == "Episode Title.txt")
        #expect(export.file(for: nil) == airDrop)
        #expect(try String(contentsOf: airDrop, encoding: .utf8).contains("Thought 📝"))
        let notes = export.file(for: "com.apple.mobilenotes.SharingExtension")
        #expect(notes.pathExtension == "md")
        #expect(try String(contentsOf: notes, encoding: .utf8).hasPrefix("# Episode/Title\n## Show\n\n*Private Notes from opencast:*"))
        export.removeFiles()
        #expect(!FileManager.default.fileExists(atPath: export.directory.path))
    }

    @Test("Unicode episode titles produce filenames within filesystem byte limits")
    func unicodeFilename() throws {
        let export = try EpisodeNotesShare(episodeTitle: String(repeating: "📝", count: 100), showTitle: "Show", notes: [])
        defer { export.removeFiles() }
        #expect(export.textURL.lastPathComponent.utf8.count <= 255)
        #expect(FileManager.default.fileExists(atPath: export.textURL.path))
    }

}
