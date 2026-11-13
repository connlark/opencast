public enum PublisherChaptersDocumentError: Error, Equatable {
    /// The bytes do not parse as JSON, including nesting deeper than the parser accepts.
    case invalidJSON
    /// The root is not an object whose `chapters` is an array.
    case malformedRoot
}
