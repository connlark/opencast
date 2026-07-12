import Foundation

enum OpenCastRemoteModelFilePath {
    static func components(for path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              parts.allSatisfy(isSafePathComponent),
              parts[0] == "model" || parts[0] == "tokenizer" else {
            throw OpenCastTranscriptionError.invalidRemoteManifest("bad file path: \(path)")
        }
        return parts
    }

    static func destinationURL(for path: String, rootDirectory: URL) throws -> URL {
        try components(for: path).reduce(rootDirectory) { url, part in
            url.appending(path: part)
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\\")
    }
}
