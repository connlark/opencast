import Foundation
import SwiftUI

/// Loads car-sized artwork after a list renders and patches rows in place.
/// Patches are serial with a short gap: CarPlay stalls the main thread when a
/// burst of `setImage(_:)` calls lands in one runloop pass.
final class CarPlayArtworkPatcher {
    /// One scope per list: a re-render of one tab must not cancel artwork still
    /// loading for a tab that did not change.
    enum Scope: Hashable {
        case inbox
        case library
        case downloads
        case pushed
    }

    private static let patchInterval = Duration.milliseconds(16)

    private var tasks: [Scope: Task<Void, Never>] = [:]

    func patch(_ targets: [CarPlayArtworkTarget], sizing: CarPlayArtworkSizing, scope: Scope) {
        tasks[scope]?.cancel()
        guard !targets.isEmpty else {
            tasks[scope] = nil
            return
        }

        tasks[scope] = Task {
            await Self.patch(targets, sizing: sizing)
        }
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    private static func patch(_ targets: [CarPlayArtworkTarget], sizing: CarPlayArtworkSizing) async {
        var loadedImages: [ArtworkRequest: UIImage?] = [:]

        for target in targets {
            guard !Task.isCancelled else {
                return
            }

            let request = ArtworkRequest(url: target.artworkURL, targetPixelSize: sizing.pixelSize)
            let image: UIImage?
            if let loadedImage = loadedImages[request] {
                image = loadedImage
            } else {
                let loadedImage = try? await ArtworkLoader.shared.image(
                    for: request,
                    cacheKind: target.cacheKind
                )
                image = loadedImage.map(sizing.matchingCarScale)
                loadedImages[request] = image
            }

            // A failed load leaves the first-paint image in place; CarPlay keeps
            // the previous image rather than blanking the row.
            guard let image, !Task.isCancelled else {
                continue
            }

            target.item.setImage(image)
            try? await Task.sleep(for: patchInterval)
        }
    }
}
