import Observation
import UIKit

protocol AlternateIconApplying {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}

extension UIApplication: AlternateIconApplying {}

/// UIKit persists the chosen icon per device: nothing goes to SwiftData, and Delete Data leaves it.
@Observable
final class AppIconStore {
    private(set) var selection = AppIconOption.primary
    private(set) var isSupported = true
    private(set) var isApplying = false
    private(set) var lastErrorMessage: String?
    @ObservationIgnored private let injectedApplication: (any AlternateIconApplying)?

    init(application: (any AlternateIconApplying)? = nil) {
        injectedApplication = application
    }

    /// Resolved per call: the app model is built before `UIApplicationMain` creates the app, so
    /// `UIApplication.shared` captured in `init` is nil-backed, silently returns false or nil, and
    /// its async icon change never resumes.
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
