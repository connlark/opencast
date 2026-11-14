import CryptoKit
import Foundation
import Testing

/// `Corpus/PROVENANCE.md` against the files it describes: each file has exactly one row, and the row's byte count and
/// SHA-256 are those of the file in the bundle. A corpus file is the server's bytes, so any edit to one fails here,
/// including an edit that keeps its length.
@Suite("Corpus provenance")
struct CorpusProvenanceTests {
    /// Each `Corpus/` directory and its files' extension; PROVENANCE.md names the directory in its table's heading.
    static let directories = [("feeds", "xml"), ("chapters", "json")]

    @Test("Every corpus file has exactly one provenance row", arguments: directories)
    func oneRowPerFile(directory: String, fileExtension: String) throws {
        let rows = try Self.rows(for: directory)
        let files = try Self.files(in: directory, fileExtension: fileExtension)

        #expect(!files.isEmpty)
        for name in files.keys.sorted() {
            #expect(rows.count { $0.file == name } == 1, "\(directory)/\(name)")
        }
    }

    @Test("Every provenance row names a corpus file", arguments: directories)
    func rowsNameFiles(directory: String, fileExtension: String) throws {
        let rows = try Self.rows(for: directory)
        let files = try Self.files(in: directory, fileExtension: fileExtension)

        #expect(!rows.isEmpty)
        for row in rows {
            #expect(files[row.file] != nil, "\(directory)/\(row.file)")
        }
    }

    @Test("Every provenance row's Bytes cell is its file's size in the bundle", arguments: directories)
    func bytesMatchFiles(directory: String, fileExtension: String) throws {
        let rows = try Self.rows(for: directory)
        let files = try Self.files(in: directory, fileExtension: fileExtension)

        for row in rows {
            if let file = files[row.file] {
                #expect(try Int(row.bytes) == file.resourceValues(forKeys: [.fileSizeKey]).fileSize, "\(directory)/\(row.file)")
            }
        }
    }

    /// The size check misses an edit that keeps a file's length; the digest covers every byte.
    @Test("Every provenance row's SHA-256 cell is the digest of its file's bytes in the bundle", arguments: directories)
    func digestsMatchFiles(directory: String, fileExtension: String) throws {
        let rows = try Self.rows(for: directory)
        let files = try Self.files(in: directory, fileExtension: fileExtension)

        for row in rows {
            if let file = files[row.file] {
                let digest = try SHA256.hash(data: Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                #expect(row.sha256 == digest, "\(directory)/\(row.file)")
            }
        }
    }

    /// The File, Bytes and SHA-256 cells of each row in the table under the heading that names `directory`.
    private static func rows(for directory: String) throws -> [(file: String, bytes: String, sha256: String)] {
        let url = try #require(Bundle.module.url(forResource: "PROVENANCE", withExtension: "md", subdirectory: "Corpus"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        let heading = try #require(lines.firstIndex { $0.hasPrefix("## ") && $0.contains("(`\(directory)/`)") })
        let table = lines[(heading + 1)...]
            .prefix { !$0.hasPrefix("## ") }
            .filter { $0.hasPrefix("|") }
            .map(cells)
        let header = try #require(table.first)
        let file = try #require(header.firstIndex(of: "File"))
        let bytes = try #require(header.firstIndex(of: "Bytes"))
        let sha256 = try #require(header.firstIndex(of: "SHA-256"))
        try #require(table.dropFirst().first?.allSatisfy { $0.hasPrefix("---") } == true, "no delimiter row")

        return try table.dropFirst(2).map { row in
            try #require(row.count == header.count, "a \(directory) row has \(row.count) cells, not \(header.count)")
            return (row[file].trimmingCharacters(in: ["`"]), row[bytes], row[sha256])
        }
    }

    /// A Markdown table row's cells, split at every pipe not escaped as `\|`.
    private static func cells(_ row: Substring) -> [String] {
        var cells = [""]
        var previous: Character?
        for character in row {
            if character == "|", previous != "\\" {
                cells.append("")
            } else {
                cells[cells.count - 1].append(character)
            }
            previous = character
        }
        return cells.dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func files(in directory: String, fileExtension: String) throws -> [String: URL] {
        let folder = try #require(Bundle.module.resourceURL).appending(path: "Corpus/\(directory)", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == fileExtension }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0) })
    }
}
