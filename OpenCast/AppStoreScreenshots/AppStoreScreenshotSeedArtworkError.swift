#if DEBUG
import Foundation

enum AppStoreScreenshotSeedArtworkError: LocalizedError {
    case missing(name: String, subdirectory: String)

    var errorDescription: String? {
        switch self {
        case .missing(let name, let subdirectory):
            "Missing App Store screenshot artwork fixture \(name).png in bundle subdirectory \(subdirectory). Build screenshot captures with OPENCAST_INCLUDE_APP_STORE_SCREENSHOT_FIXTURES=YES."
        }
    }
}
#endif
