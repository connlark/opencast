import Foundation

public struct OpenCastWhisperModelInstallLimits: Sendable, Equatable {
    public var maximumFileByteCount: Int64
    public var maximumTotalByteCount: Int64

    public init(maximumFileByteCount: Int64, maximumTotalByteCount: Int64) {
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumTotalByteCount = maximumTotalByteCount
    }

    public static let largeV3 = OpenCastWhisperModelInstallLimits(
        maximumFileByteCount: 512 * 1_024 * 1_024,
        maximumTotalByteCount: 800 * 1_024 * 1_024
    )
}
