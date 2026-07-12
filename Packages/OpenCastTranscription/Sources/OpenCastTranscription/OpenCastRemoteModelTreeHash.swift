import Foundation

enum OpenCastRemoteModelTreeHash {
    static func hash(files: [RemoteWhisperModelFile]) -> String {
        let canonical = files.sorted { $0.path < $1.path }.reduce(into: Data()) { data, file in
            data.append(Data(file.path.utf8))
            data.append(0)
            data.append(Data(file.sha256.lowercased().utf8))
            data.append(0)
            data.append(Data(String(file.byteCount).utf8))
            data.append(10)
        }
        return OpenCastSHA256.hash(canonical)
    }
}
