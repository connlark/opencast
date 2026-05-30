@preconcurrency import MediaPlayer

nonisolated func makeNowPlayingArtwork(from image: NowPlayingArtworkImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: nowPlayingArtworkBoundsSize(for: image)) { _ in
        image
    }
}

private nonisolated func nowPlayingArtworkBoundsSize(for image: NowPlayingArtworkImage) -> CGSize {
    let size = image.size
    guard size.width.isFinite,
          size.height.isFinite,
          size.width > 0,
          size.height > 0
    else {
        return CGSize(width: 512, height: 512)
    }

    return size
}
