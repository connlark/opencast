import SwiftUI

/// Narrow UIKit wrapper for a share sheet presented programmatically (after
/// an asynchronous export, for instance), which `ShareLink` cannot do.
struct ActivityViewControllerSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Runs when the sheet is torn down, after any activity has finished
    /// reading the items; temporary files are removed here.
    var onDismantle: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismantle: onDismantle)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }

    static func dismantleUIViewController(_ uiViewController: UIActivityViewController, coordinator: Coordinator) {
        coordinator.onDismantle?()
    }

    final class Coordinator {
        let onDismantle: (() -> Void)?

        init(onDismantle: (() -> Void)?) {
            self.onDismantle = onDismantle
        }
    }
}
