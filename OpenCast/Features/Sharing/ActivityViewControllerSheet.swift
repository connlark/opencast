import SwiftUI

/// For a share sheet presented programmatically, which `ShareLink` cannot do.
struct ActivityViewControllerSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Runs at teardown, after any activity has finished reading the items.
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
