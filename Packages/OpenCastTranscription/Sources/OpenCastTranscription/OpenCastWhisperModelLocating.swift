public protocol OpenCastWhisperModelLocating: Sendable {
    func modelLocation() throws -> OpenCastWhisperModelLocation
}
