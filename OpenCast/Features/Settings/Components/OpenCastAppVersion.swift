import Foundation

nonisolated enum OpenCastAppVersion {
    static let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    /// `CFBundleVersion` as an integer for remote-content build gates.
    static var buildNumber: Int? {
        build.flatMap(Int.init)
    }

    static var displayText: String {
        switch (shortVersion, build) {
        case let (version?, build?):
            "\(version) (\(build))"
        case let (version?, nil):
            version
        case let (nil, build?):
            "Build \(build)"
        case (nil, nil):
            "Unavailable"
        }
    }
}
