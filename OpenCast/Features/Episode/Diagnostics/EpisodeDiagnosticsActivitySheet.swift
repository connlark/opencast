import SwiftUI

/// Narrow UIKit wrapper: after the asynchronous download finishes, the share
/// sheet must present programmatically, which `ShareLink` cannot do.
struct EpisodeDiagnosticsActivitySheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
