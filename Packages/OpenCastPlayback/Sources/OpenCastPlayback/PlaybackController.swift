import Foundation
import OpenCastCore

public protocol PlaybackController: AnyObject {
    /// Aggregate state for consumers that need one value; prefer flat properties for SwiftUI observation.
    var snapshot: PlaybackSnapshot { get }
    var currentEpisode: Episode? { get }
    var state: PlaybackState { get }
    var position: TimeInterval { get }
    var duration: TimeInterval? { get }
    var progress: Double { get }
    var progressBoundaryID: Int { get }
    var rate: Float { get }
    var sleepTimerEndsAt: Date? { get }

    func load(_ episode: Episode, startPosition: TimeInterval) throws
    func play()
    func pause()
    func unload()
    func togglePlayPause()
    func seek(to position: TimeInterval)
    func skip(by interval: TimeInterval)
    func setRate(_ rate: Float)
    func setSleepTimer(duration: TimeInterval?)
}
