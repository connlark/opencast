@preconcurrency import MediaPlayer

final class SystemNowPlayingInfoCenter: NowPlayingInfoPublishing {
    var nowPlayingInfo: [String: Any]? {
        get {
            MPNowPlayingInfoCenter.default().nowPlayingInfo
        }
        set {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = newValue
        }
    }
}
