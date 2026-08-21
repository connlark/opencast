@preconcurrency import AVFoundation

typealias PlaybackAudioSessionActivation = @Sendable () async throws -> Bool
typealias PlaybackAudioSessionDeactivation = @Sendable () async throws -> Void

@concurrent
func activateSystemPlaybackAudioSession() async throws -> Bool {
    try Task.checkCancellation()
    #if os(iOS) || os(tvOS) || os(visionOS)
    let session = AVAudioSession.sharedInstance()
    do {
        try activatePlaybackAudioSessionOnce(session)
        try Task.checkCancellation()
        return false
    } catch is CancellationError {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        throw CancellationError()
    } catch {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        do {
            try activatePlaybackAudioSessionOnce(session)
            try Task.checkCancellation()
            return true
        } catch is CancellationError {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CancellationError()
        }
    }
    #else
    return false
    #endif
}

/// Deactivation is a synchronous XPC round trip to the media server (~15 ms
/// on an M3 iPad), so it runs off the main actor like activation does.
@concurrent
func deactivateSystemPlaybackAudioSession() async throws {
    #if os(iOS) || os(tvOS) || os(visionOS)
    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
}

#if os(iOS) || os(tvOS) || os(visionOS)
private nonisolated func activatePlaybackAudioSessionOnce(_ session: AVAudioSession) throws {
    try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    try session.setActive(true)
}
#endif
