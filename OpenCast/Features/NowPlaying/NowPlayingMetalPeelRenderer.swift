@preconcurrency import MetalKit
import UIKit

final class NowPlayingMetalPeelRenderer: NSObject, MTKViewDelegate {
    var onProgressChanged: (@MainActor (CGFloat) -> Void)?
    var onArtworkTextureReadinessChanged: (@MainActor (Bool) -> Void)?

    private weak var metalView: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let sampler: MTLSamplerState?
    private let artworkPipeline: MTLRenderPipelineState?
    private let colorPipeline: MTLRenderPipelineState?
    private let inFlightSemaphore: DispatchSemaphore
    private let simulation: NowPlayingPeelSimulation
    private let indexBuffer: MTLBuffer?
    private let indexCount: Int
    private let vertexCapacity: Int
    private let lipVertexCapacity: Int

    private var artworkVertexBuffers: [MTLBuffer] = []
    private var shadowVertexBuffers: [MTLBuffer] = []
    private var lipVertexBuffers: [MTLBuffer] = []
    private var artworkTexture: MTLTexture?
    private var textureTask: Task<Void, Never>?
    private var textureRequestID = 0
    private var frameIndex = 0
    private var currentTouchY: Float = 0.76
    private var reduceMotion = false
    private var targetProgress: Float = 0
    private var pendingSettleVelocity: Float?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var lastProgressReportTimestamp: CFTimeInterval?
    private var lastReportedProgress: Float?

    var isSettling: Bool {
        displayLink != nil
    }

    init?(device: MTLDevice, metalView: MTKView) {
        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        let simulation = NowPlayingPeelSimulation()
        self.device = device
        self.metalView = metalView
        self.commandQueue = commandQueue
        self.simulation = simulation
        inFlightSemaphore = DispatchSemaphore(value: Self.maxFramesInFlight)
        indexCount = simulation.indexCount
        vertexCapacity = simulation.vertexCapacity
        lipVertexCapacity = (simulation.topology.rows - 1) * 12
        indexBuffer = Self.makeIndexBuffer(device: device, indices: simulation.topology.indices)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)

        let library = device.makeDefaultLibrary()
        artworkPipeline = Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: metalView.colorPixelFormat,
            fragmentName: "nowPlayingPeelArtworkFragment"
        )
        colorPipeline = Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: metalView.colorPixelFormat,
            fragmentName: "nowPlayingPeelColorFragment"
        )
        artworkVertexBuffers = Self.makeVertexBuffers(device: device, capacity: vertexCapacity)
        shadowVertexBuffers = Self.makeVertexBuffers(device: device, capacity: vertexCapacity)
        lipVertexBuffers = Self.makeVertexBuffers(device: device, capacity: lipVertexCapacity)
        super.init()
        metalView.delegate = self
    }

    isolated deinit {
        displayLink?.invalidate()
        textureTask?.cancel()
    }

    func setArtworkImage(_ image: UIImage) {
        textureTask?.cancel()
        textureRequestID += 1
        let requestID = textureRequestID
        artworkTexture = nil
        onArtworkTextureReadinessChanged?(false)
        render()

        guard let cgImage = image.cgImage else {
            return
        }

        let device = self.device
        textureTask = Task { [weak self, cgImage] in
            let loadedTexture = await Self.makeArtworkTexture(from: cgImage, device: device)
            guard !Task.isCancelled else {
                return
            }

            Task { @MainActor [weak self, loadedTexture] in
                self?.finishArtworkTexture(loadedTexture.texture, requestID: requestID)
            }
        }
    }

    @concurrent
    private static func makeArtworkTexture(
        from cgImage: CGImage,
        device: MTLDevice
    ) async -> NowPlayingMetalPeelLoadedTexture {
        let imageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let canvasSize = NowPlayingArtworkCanvas.squareSize(for: imageSize)
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bufferSize = bytesPerRow * height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let buffer = malloc(bufferSize)
        else {
            return NowPlayingMetalPeelLoadedTexture(texture: nil)
        }
        defer { free(buffer) }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return NowPlayingMetalPeelLoadedTexture(texture: nil)
        }

        context.interpolationQuality = .high
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        context.draw(
            cgImage,
            in: NowPlayingArtworkCanvas.aspectFitRect(imageSize: imageSize, canvasSize: canvasSize)
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return NowPlayingMetalPeelLoadedTexture(texture: nil)
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        texture.replace(region: region, mipmapLevel: 0, withBytes: buffer, bytesPerRow: bytesPerRow)
        return NowPlayingMetalPeelLoadedTexture(texture: texture)
    }

    private func finishArtworkTexture(_ texture: MTLTexture?, requestID: Int) {
        guard requestID == textureRequestID else {
            return
        }

        artworkTexture = texture
        onArtworkTextureReadinessChanged?(texture != nil)
        render()
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard self.reduceMotion != reduceMotion else {
            return
        }

        self.reduceMotion = reduceMotion
        simulation.step(
            input: NowPlayingPeelSimulationInput(
                progress: simulation.progress,
                touchY: currentTouchY,
                targetProgress: targetProgress,
                normalizedVelocity: 0,
                isInteracting: false,
                reduceMotion: reduceMotion
            ),
            deltaTime: 1 / 120
        )
        render()
    }

    func setInteractiveProgress(_ progress: CGFloat, touchY: CGFloat) {
        stopSettling()
        currentTouchY = Float(touchY.clamped01)
        targetProgress = Float(progress.clamped01)
        simulation.step(
            input: NowPlayingPeelSimulationInput(
                progress: Float(progress.clamped01),
                touchY: currentTouchY,
                targetProgress: targetProgress,
                normalizedVelocity: 0,
                isInteracting: true,
                reduceMotion: reduceMotion
            ),
            deltaTime: 1 / 120
        )
        render()
    }

    func settle(to targetProgress: CGFloat, initialVelocity: CGFloat, touchY: CGFloat) {
        stopSettling()
        self.targetProgress = Float(targetProgress.clamped01)
        currentTouchY = Float(touchY.clamped01)
        pendingSettleVelocity = Float(initialVelocity.clamped(to: -8...8))
        lastTimestamp = nil
        resetProgressReportThrottle()

        let displayLink = CADisplayLink(target: self, selector: #selector(stepSettle))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stopSettling() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        resetProgressReportThrottle()
        pendingSettleVelocity = nil
    }

    func stopRendering() {
        stopSettling()
        textureTask?.cancel()
        textureTask = nil
        textureRequestID += 1
        onArtworkTextureReadinessChanged?(false)
    }

    func render() {
        metalView?.draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        render()
    }

    func draw(in view: MTKView) {
        drawFrame(in: view)
    }

    private func drawFrame(in metalView: MTKView) {
        guard
            let drawable = metalView.currentDrawable,
            let renderPassDescriptor = metalView.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            semaphore.signal()
            return
        }

        let currentFrameIndex = frameIndex
        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight

        drawShadowMesh(frameIndex: currentFrameIndex, encoder: encoder)
        drawArtworkMesh(frameIndex: currentFrameIndex, encoder: encoder)
        drawLipMesh(frameIndex: currentFrameIndex, encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary?,
        pixelFormat: MTLPixelFormat,
        fragmentName: String
    ) -> MTLRenderPipelineState? {
        guard let vertexFunction = library?.makeFunction(name: "nowPlayingPeelVertex"),
              let fragmentFunction = library?.makeFunction(name: fragmentName)
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeVertexBuffers(device: MTLDevice, capacity: Int) -> [MTLBuffer] {
        let length = MemoryLayout<NowPlayingMetalPeelVertex>.stride * capacity
        return (0..<maxFramesInFlight).compactMap { _ in
            device.makeBuffer(length: length, options: .storageModeShared)
        }
    }

    private static func makeIndexBuffer(device: MTLDevice, indices: [UInt16]) -> MTLBuffer? {
        indices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
        }
    }

    @objc private func stepSettle(_ displayLink: CADisplayLink) {
        let dt = settleDelta(for: displayLink)
        let initialVelocity = pendingSettleVelocity ?? 0
        pendingSettleVelocity = nil
        simulation.step(
            input: NowPlayingPeelSimulationInput(
                progress: simulation.progress,
                touchY: currentTouchY,
                targetProgress: targetProgress,
                normalizedVelocity: initialVelocity,
                isInteracting: false,
                reduceMotion: reduceMotion
            ),
            deltaTime: Float(dt)
        )

        render()
        reportSettleProgress(timestamp: displayLink.timestamp)

        guard abs(simulation.progress - targetProgress) < 0.0015 else {
            return
        }

        simulation.reset(progress: targetProgress)
        render()
        reportSettleProgress(timestamp: displayLink.timestamp, force: true)
        stopSettling()
    }

    private func settleDelta(for displayLink: CADisplayLink) -> CGFloat {
        guard let lastTimestamp else {
            self.lastTimestamp = displayLink.timestamp
            return 1 / 60
        }

        let delta = displayLink.timestamp - lastTimestamp
        self.lastTimestamp = displayLink.timestamp
        return CGFloat(delta).clamped(to: (1 / 60)...(1 / 30))
    }

    private func resetProgressReportThrottle() {
        lastProgressReportTimestamp = nil
        lastReportedProgress = nil
    }

    private func reportSettleProgress(timestamp: CFTimeInterval, force: Bool = false) {
        let nextProgress = simulation.progress

        if !force {
            if let lastProgressReportTimestamp,
               timestamp - lastProgressReportTimestamp < Self.progressReportInterval {
                return
            }

            if let lastReportedProgress,
               abs(lastReportedProgress - nextProgress) < 0.0005 {
                return
            }
        }

        lastProgressReportTimestamp = timestamp
        lastReportedProgress = nextProgress
        onProgressChanged?(CGFloat(nextProgress))
    }

    private func drawArtworkMesh(frameIndex: Int, encoder: MTLRenderCommandEncoder) {
        guard let artworkPipeline,
              let artworkTexture,
              let sampler,
              let indexBuffer,
              let buffer = vertexBuffer(from: artworkVertexBuffers, frameIndex: frameIndex)
        else {
            return
        }

        let vertexCount = fillArtworkVertices(in: buffer)
        guard vertexCount > 0 else {
            return
        }

        var uniforms = uniforms
        encoder.setRenderPipelineState(artworkPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(artworkTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NowPlayingMetalPeelUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func drawShadowMesh(frameIndex: Int, encoder: MTLRenderCommandEncoder) {
        guard let colorPipeline,
              let indexBuffer,
              let buffer = vertexBuffer(from: shadowVertexBuffers, frameIndex: frameIndex)
        else {
            return
        }

        let vertexCount = fillShadowVertices(in: buffer)
        guard vertexCount > 0 else {
            return
        }

        encoder.setRenderPipelineState(colorPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func drawLipMesh(frameIndex: Int, encoder: MTLRenderCommandEncoder) {
        guard let buffer = vertexBuffer(from: lipVertexBuffers, frameIndex: frameIndex) else {
            return
        }

        let vertexCount = fillLipVertices(in: buffer)
        drawColorMesh(buffer: buffer, vertexCount: vertexCount, encoder: encoder)
    }

    private func drawColorMesh(buffer: MTLBuffer, vertexCount: Int, encoder: MTLRenderCommandEncoder) {
        guard let colorPipeline,
              vertexCount > 0
        else {
            return
        }

        encoder.setRenderPipelineState(colorPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    private func vertexBuffer(from buffers: [MTLBuffer], frameIndex: Int) -> MTLBuffer? {
        guard buffers.count == Self.maxFramesInFlight else {
            return nil
        }

        return buffers[frameIndex]
    }

    private var uniforms: NowPlayingMetalPeelUniforms {
        NowPlayingMetalPeelUniforms(
            progress: simulation.progress.clamped01,
            touchY: currentTouchY.clamped01,
            reduceMotion: reduceMotion ? 1 : 0
        )
    }

    private func fillArtworkVertices(in buffer: MTLBuffer) -> Int {
        let pointer = buffer.contents().bindMemory(
            to: NowPlayingMetalPeelVertex.self,
            capacity: vertexCapacity
        )

        return simulation.withCurrentFrame { vertices, _, _ in
            for index in vertices.indices {
                pointer[index] = metalVertex(from: vertices[index], color: SIMD4<Float>(1, 1, 1, 1))
            }
            return vertices.count
        }
    }

    private func fillShadowVertices(in buffer: MTLBuffer) -> Int {
        let p = simulation.progress.clamped01
        guard p > 0.01 else {
            return 0
        }

        let pointer = buffer.contents().bindMemory(
            to: NowPlayingMetalPeelVertex.self,
            capacity: vertexCapacity
        )

        return simulation.withCurrentFrame { vertices, _, _ in
            for index in vertices.indices {
                let vertex = vertices[index]
                let shadowStrength = max(vertex.lift, vertex.foldIntensity * 0.35) * vertex.released
                let alpha = (reduceMotion ? 0.04 : 0.105) * p * shadowStrength
                let offset = 0.010 + 0.030 * shadowStrength + 0.010 * p
                let point = SIMD3(
                    vertex.position.x + offset,
                    vertex.position.y + offset * 0.82,
                    0
                )
                let shadowVertex = NowPlayingPeelSimulationVertex(
                    position: point,
                    restPosition: vertex.restPosition,
                    uv: vertex.uv,
                    lift: vertex.lift,
                    foldIntensity: vertex.foldIntensity,
                    released: vertex.released,
                    tack: vertex.tack
                )
                pointer[index] = metalVertex(
                    from: shadowVertex,
                    color: SIMD4<Float>(0, 0, 0, alpha.clamped01)
                )
            }
            return vertices.count
        }
    }

    private func fillLipVertices(in buffer: MTLBuffer) -> Int {
        let p = simulation.progress.clamped01
        guard !reduceMotion, p > 0.04 else {
            return 0
        }

        let pointer = buffer.contents().bindMemory(
            to: NowPlayingMetalPeelVertex.self,
            capacity: lipVertexCapacity
        )
        var vertexIndex = 0
        let lastColumn = simulation.topology.columns - 1

        simulation.withCurrentFrame { vertices, _, _ in
            for row in 0..<(simulation.topology.rows - 1) {
                let row0 = lipRowPoints(vertex: vertices[simulation.topology.index(column: lastColumn, row: row)])
                let row1 = lipRowPoints(vertex: vertices[simulation.topology.index(column: lastColumn, row: row + 1)])
                appendQuad(
                    to: pointer,
                    index: &vertexIndex,
                    topLeft: row0.inner,
                    topRight: row0.highlight,
                    bottomLeft: row1.inner,
                    bottomRight: row1.highlight
                )
                appendQuad(
                    to: pointer,
                    index: &vertexIndex,
                    topLeft: row0.highlight,
                    topRight: row0.outer,
                    bottomLeft: row1.highlight,
                    bottomRight: row1.outer
                )
            }
        }

        return vertexIndex
    }

    private func lipRowPoints(vertex: NowPlayingPeelSimulationVertex) -> (
        inner: NowPlayingMetalPeelVertex,
        highlight: NowPlayingMetalPeelVertex,
        outer: NowPlayingMetalPeelVertex
    ) {
        let p = simulation.progress.clamped01
        let touchFalloff = exp(-pow((vertex.restPosition.y - currentTouchY) * 3.0, 2))
        let width = 0.004 + 0.010 * p + 0.014 * vertex.lift + 0.004 * touchFalloff * p
        let wobble = sin((vertex.restPosition.y - currentTouchY) * .pi * 2.0) * 0.0013 * p
        let alpha = min(0.58, 0.12 + p * 0.44 + vertex.foldIntensity * 0.08)
        let edge = vertex.position

        return (
            colorVertex(
                point: SIMD3(edge.x - width * 0.64, edge.y + wobble * 0.80, 0),
                uv: vertex.uv,
                color: SIMD4<Float>(0.54, 0.48, 0.37, alpha * 0.34)
            ),
            colorVertex(
                point: SIMD3(edge.x + width * 0.16, edge.y - wobble * 0.30, 0),
                uv: vertex.uv,
                color: SIMD4<Float>(1.00, 0.985, 0.88, alpha)
            ),
            colorVertex(
                point: SIMD3(edge.x + width * 0.94, edge.y - wobble, 0),
                uv: vertex.uv,
                color: SIMD4<Float>(0.98, 0.94, 0.82, alpha * 0.38)
            )
        )
    }

    private func appendQuad(
        to pointer: UnsafeMutablePointer<NowPlayingMetalPeelVertex>,
        index: inout Int,
        topLeft: NowPlayingMetalPeelVertex,
        topRight: NowPlayingMetalPeelVertex,
        bottomLeft: NowPlayingMetalPeelVertex,
        bottomRight: NowPlayingMetalPeelVertex
    ) {
        pointer[index] = topLeft
        pointer[index + 1] = bottomLeft
        pointer[index + 2] = topRight
        pointer[index + 3] = topRight
        pointer[index + 4] = bottomLeft
        pointer[index + 5] = bottomRight
        index += 6
    }

    private func metalVertex(
        from vertex: NowPlayingPeelSimulationVertex,
        color: SIMD4<Float>
    ) -> NowPlayingMetalPeelVertex {
        NowPlayingMetalPeelVertex(
            position: clipPosition(for: vertex.position),
            texCoord: vertex.uv,
            color: color,
            material: SIMD4(vertex.lift, vertex.foldIntensity, vertex.released, vertex.tack)
        )
    }

    private func colorVertex(
        point: SIMD3<Float>,
        uv: SIMD2<Float>,
        color: SIMD4<Float>
    ) -> NowPlayingMetalPeelVertex {
        NowPlayingMetalPeelVertex(
            position: clipPosition(for: point),
            texCoord: uv,
            color: color,
            material: .zero
        )
    }

    private func clipPosition(for point: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(
            point.x * 2 - 1,
            1 - point.y * 2
        )
    }

    private static let maxFramesInFlight = 3
    private static let progressReportInterval: CFTimeInterval = 1 / 30
}
