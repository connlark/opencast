import MetalKit
import UIKit

final class NowPlayingMetalPeelUIView: UIView {
    private let imageView = UIImageView()
    private var metalView: MTKView?
    private var renderer: NowPlayingMetalPeelRenderer?
    private var lastImageSignature: String?
    private var lastSettleRequestID = 0
    private var lastFallbackReportedProgress: CGFloat?
    private var lastFallbackProgress: CGFloat = 0
    private var rendererArtworkReady = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        configureMetalView()
        configureFallbackImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("NowPlayingMetalPeelUIView does not support Interface Builder.")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView?.frame = bounds
        imageView.frame = bounds
        renderer?.render()
    }

    func update(
        artworkImage: UIImage,
        progress: CGFloat,
        touchY: CGFloat,
        isInteracting: Bool,
        settleTarget: CGFloat,
        settleVelocity: CGFloat,
        settleRequestID: Int,
        reduceMotion: Bool,
        onProgressChanged: @escaping @MainActor (CGFloat) -> Void
    ) {
        updateArtworkImage(artworkImage)
        renderer?.onProgressChanged = onProgressChanged
        renderer?.setReduceMotion(reduceMotion)

        if reduceMotion {
            renderer?.stopSettling()
            renderer?.setInteractiveProgress(progress, touchY: touchY)
            updateFallbackImage(progress: progress)
            if renderer == nil {
                reportFallbackProgress(progress, onProgressChanged: onProgressChanged)
            }
            return
        }

        if settleRequestID != lastSettleRequestID {
            lastSettleRequestID = settleRequestID
            renderer?.settle(to: settleTarget, initialVelocity: settleVelocity, touchY: touchY)
            updateFallbackImage(progress: settleTarget)
            if renderer == nil {
                reportFallbackProgress(settleTarget, onProgressChanged: onProgressChanged)
            }
            return
        }

        if isInteracting || renderer?.isSettling != true {
            renderer?.setInteractiveProgress(progress, touchY: touchY)
            updateFallbackImage(progress: progress)
            if renderer == nil {
                reportFallbackProgress(progress, onProgressChanged: onProgressChanged)
            }
        }
    }

    func stopRendering() {
        renderer?.stopRendering()
    }

    private func configureMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        let metalView = MTKView(frame: .zero, device: device)
        metalView.backgroundColor = .clear
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = true
        metalView.isOpaque = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = 60
        // Without an explicit colorspace, the compositor leaves the sRGB-encoded drawable
        // color-untagged, and on P3 hardware it gets reinterpreted in the display's native
        // space — which is what made the artwork look subtly off compared to UIKit rendering.
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        addSubview(metalView)
        self.metalView = metalView
        renderer = NowPlayingMetalPeelRenderer(device: device, metalView: metalView)
        renderer?.onArtworkTextureReadinessChanged = { [weak self] isReady in
            self?.updateRendererArtworkReadiness(isReady)
        }
    }

    private func configureFallbackImageView() {
        imageView.backgroundColor = .black
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    private func updateArtworkImage(_ image: UIImage) {
        let signature = imageSignature(for: image)
        guard signature != lastImageSignature else {
            return
        }

        lastImageSignature = signature
        rendererArtworkReady = false
        imageView.image = image
        updateFallbackImage(progress: lastFallbackProgress)
        renderer?.setArtworkImage(image)
    }

    private func updateFallbackImage(progress: CGFloat) {
        lastFallbackProgress = progress.clamped01
        let shouldHideFallback = metalView != nil && rendererArtworkReady
        imageView.isHidden = shouldHideFallback
        imageView.alpha = metalView != nil && !rendererArtworkReady
            ? 1
            : 1 - 0.10 * lastFallbackProgress
        imageView.transform = CGAffineTransform(
            translationX: -bounds.width * 0.72 * lastFallbackProgress,
            y: 0
        )
    }

    private func updateRendererArtworkReadiness(_ isReady: Bool) {
        guard rendererArtworkReady != isReady else {
            return
        }

        rendererArtworkReady = isReady
        updateFallbackImage(progress: lastFallbackProgress)
    }

    private func reportFallbackProgress(
        _ progress: CGFloat,
        onProgressChanged: @escaping @MainActor (CGFloat) -> Void
    ) {
        let nextProgress = progress.clamped01
        guard lastFallbackReportedProgress.map({ abs($0 - nextProgress) > 0.0001 }) ?? true else {
            return
        }

        lastFallbackReportedProgress = nextProgress
        Task { @MainActor in
            onProgressChanged(nextProgress)
        }
    }

    private func imageSignature(for image: UIImage) -> String {
        let cgImageSignature = image.cgImage.map { "\(ObjectIdentifier($0).hashValue)" } ?? "nil"
        return "\(cgImageSignature)|\(image.size.width)x\(image.size.height)@\(image.scale)"
    }
}
