import Foundation

protocol NowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
}
