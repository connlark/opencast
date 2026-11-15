import Foundation

/// The short sound played over an automatic ad skip.
protocol PlaybackSkipCuePlaying: AnyObject {
    /// True from a `play()` that started the sound until it finishes or is stopped.
    var isSounding: Bool { get }
    /// Called when the sound plays to its end, never after `stop()`.
    var onFinish: (@MainActor () -> Void)? { get set }

    /// Plays from the start. False when the sound did not start.
    func play() -> Bool
    func stop()
}

/// Opens and prepares a cue. Preparing or playing an `AVAudioPlayer`
/// activates the audio session implicitly, so the controller calls this only
/// while its own bookkeeping holds the session.
typealias PlaybackSkipCuePlayerFactory = @MainActor (URL) throws -> any PlaybackSkipCuePlaying
