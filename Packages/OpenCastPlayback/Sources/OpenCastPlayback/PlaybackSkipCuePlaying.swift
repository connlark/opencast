import Foundation

protocol PlaybackSkipCuePlaying: AnyObject {
    var isSounding: Bool { get }
    /// Called when the sound plays to its end, never after `stop()`.
    var onFinish: (@MainActor () -> Void)? { get set }

    /// Plays from the start. False when the sound did not start.
    func play() -> Bool
    func stop()
}

/// Preparing or playing an `AVAudioPlayer` activates the audio session implicitly, so call
/// this only while the controller's bookkeeping holds the session.
typealias PlaybackSkipCuePlayerFactory = @MainActor (URL) throws -> any PlaybackSkipCuePlaying
