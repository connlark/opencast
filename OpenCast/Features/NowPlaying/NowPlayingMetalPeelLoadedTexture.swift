@preconcurrency import Metal

// Texture creation happens off-main; this wrapper only transfers the completed
// handle to the main actor for storage before later render use.
nonisolated struct NowPlayingMetalPeelLoadedTexture: @unchecked Sendable {
    let texture: MTLTexture?
}
