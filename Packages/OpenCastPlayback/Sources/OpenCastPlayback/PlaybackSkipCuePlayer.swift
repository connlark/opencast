@preconcurrency import AVFoundation

/// One `AVAudioPlayer` for the skip cue. It never touches `AVAudioSession`;
/// it plays inside whatever session its owner holds.
final class PlaybackSkipCuePlayer: NSObject, PlaybackSkipCuePlaying {
    private let player: AVAudioPlayer
    /// Whether `prepare()` has succeeded. Opening the file never prepares it:
    /// preparing acquires the audio hardware, and on iOS the session with it.
    private(set) var isPrepared = false
    private(set) var isSounding = false
    var onFinish: (@MainActor () -> Void)?

    /// Opens the file without preparing it.
    init(contentsOf url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    var currentTime: TimeInterval {
        player.currentTime
    }

    func prepare() {
        isPrepared = player.prepareToPlay()
    }

    func play() -> Bool {
        // `stop()` keeps the position.
        player.currentTime = 0
        isSounding = player.play()
        return isSounding
    }

    func stop() {
        player.stop()
        isSounding = false
    }

    private func handlePlaybackFinished() {
        // A play() or stop() can land between the end and this hop; the
        // newer call owns `isSounding` then.
        guard isSounding, !player.isPlaying else {
            return
        }
        isSounding = false
        onFinish?()
    }
}

extension PlaybackSkipCuePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handlePlaybackFinished()
        }
    }

    /// A decode error ends the sound without `audioPlayerDidFinishPlaying`;
    /// left alone, `isSounding` would stay true and silence every later cue.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.handlePlaybackFinished()
        }
    }
}
