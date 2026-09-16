import Observation
import UIKit

/// The slice of `UIApplication` the store drives, so tests can substitute it.
protocol AlternateIconApplying {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}

extension UIApplication: AlternateIconApplying {}

/// UIKit persists the chosen icon per device, so nothing is written to
/// SwiftData or synced and Delete Data leaves the icon alone.
@Observable
final class AppIconStore {
    private(set) var selection = AppIconOption.ember
    private(set) var isSupported = true
    private(set) var isApplying = false
    private(set) var lastErrorMessage: String?
    @ObservationIgnored private let injectedApplication: (any AlternateIconApplying)?

    init(application: (any AlternateIconApplying)? = nil) {
        injectedApplication = application
    }

    /// Resolved per call: the app model is built in the SwiftUI `App`
    /// initializer, before `UIApplicationMain` creates the application, so
    /// capturing `UIApplication.shared` in `init` stores a nil-backed
    /// reference whose messages silently return false/nil and whose async
    /// icon change never resumes.
    private var application: any AlternateIconApplying {
        injectedApplication ?? UIApplication.shared
    }

    func load() {
        isSupported = application.supportsAlternateIcons
        selection = AppIconOption(alternateIconName: application.alternateIconName)
    }

    func select(_ option: AppIconOption) async {
        guard option != selection, !isApplying else {
            return
        }

        let previousSelection = selection
        selection = option
        isApplying = true
        defer { isApplying = false }

        do {
            try await application.setAlternateIconName(option.alternateIconName)
            lastErrorMessage = nil
        } catch {
            selection = previousSelection
            lastErrorMessage = "Unable to change the app icon: \(error.localizedDescription)"
        }
    }

    func clearLastError() {
        lastErrorMessage = nil
    }
}
