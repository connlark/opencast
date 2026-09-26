/// The last recoverable, non-terminal way a remote job run ended. It never
/// authorizes a new client request ID and never triggers `/cancel`; Resume
/// and Try Again re-attach to the same reference.
nonisolated enum RemoteTranscriptionJobExit: String, Codable, Sendable {
    /// Continued-processing expiration or scene exit stopped local polling
    /// while the server keeps working.
    case parked
    /// Transport give-up after the job was attached.
    case connectionLost
    /// A local request leg (App Attest, keychain, decode) gave up.
    case localRequestFailed
    /// The explicit episode download never completed.
    case downloadFailed
}
