import Foundation

enum NowPlayingArtworkError: Error, Equatable {
    case invalidImageData
    case unsuccessfulResponse(Int)
}
