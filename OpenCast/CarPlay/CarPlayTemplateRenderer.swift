import CarPlay
import Foundation

/// Turns browse value models into CarPlay templates. Stateless: it paints from
/// the warm artwork cache and reports which rows still need a real image.
struct CarPlayTemplateRenderer {
    let artworkSizing: CarPlayArtworkSizing

    func makeTemplate(
        for snapshot: CarPlayBrowseSnapshot,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> (template: CPListTemplate, artworkTargets: [CarPlayArtworkTarget]) {
        let rendered = render(snapshot, onSelect: onSelect)
        let template = CPListTemplate(title: snapshot.title, sections: rendered.sections)
        apply(snapshot, to: template)
        return (template, rendered.artworkTargets)
    }

    func update(
        _ template: CPListTemplate,
        with snapshot: CarPlayBrowseSnapshot,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> [CarPlayArtworkTarget] {
        let rendered = render(snapshot, onSelect: onSelect)
        template.updateSections(rendered.sections)
        apply(snapshot, to: template)
        return rendered.artworkTargets
    }

    private func render(
        _ snapshot: CarPlayBrowseSnapshot,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> CarPlayRenderedList {
        var artworkTargets: [CarPlayArtworkTarget] = []
        let sections = snapshot.sections.map { section in
            CPListSection(
                items: section.rows.map { row in
                    let rendered = makeItem(for: row, onSelect: onSelect)
                    if let target = rendered.artworkTarget {
                        artworkTargets.append(target)
                    }
                    return rendered.item
                },
                header: section.header,
                sectionIndexTitle: nil
            )
        }

        return CarPlayRenderedList(sections: sections, artworkTargets: artworkTargets)
    }

    private func apply(_ snapshot: CarPlayBrowseSnapshot, to template: CPListTemplate) {
        template.emptyViewTitleVariants = snapshot.emptyTitleVariants
        template.emptyViewSubtitleVariants = snapshot.emptySubtitleVariants
        template.showsSpinnerWhileEmpty = snapshot.showsSpinnerWhileEmpty
    }

    private func makeItem(
        for row: CarPlayListRow,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> (item: CPListItem, artworkTarget: CarPlayArtworkTarget?) {
        switch row {
        case .episode(let episodeRow):
            makeEpisodeItem(episodeRow, row: row, onSelect: onSelect)
        case .podcast(let podcastRow):
            makePodcastItem(podcastRow, row: row, onSelect: onSelect)
        case .playlists:
            (
                makeItem(
                    text: CarPlayListRow.playlistsTitle,
                    image: UIImage(systemName: "music.note.list"),
                    row: row,
                    onSelect: onSelect
                ),
                nil
            )
        case .playlist(let playlistRow):
            makePlaylistItem(playlistRow, row: row, onSelect: onSelect)
        case .showMore:
            (makeItem(text: CarPlayListRow.showMoreTitle, row: row, onSelect: onSelect), nil)
        }
    }

    private func makeEpisodeItem(
        _ episodeRow: CarPlayEpisodeRow,
        row: CarPlayListRow,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> (item: CPListItem, artworkTarget: CarPlayArtworkTarget?) {
        let artwork = artwork(for: episodeRow.artworkURL, cacheKind: .episode)
        let item = CPListItem(
            text: episodeRow.title,
            detailText: episodeRow.detailText,
            image: artwork.image,
            accessoryImage: nil,
            accessoryType: episodeRow.isDownloaded ? .none : .cloud
        )
        item.isPlaying = episodeRow.isPlaying
        item.playbackProgress = episodeRow.playbackProgress ?? 0
        item.handler = handler(for: row, onSelect: onSelect)
        return (item, artwork.pendingURL.map { url in
            CarPlayArtworkTarget(item: item, artworkURL: url, cacheKind: .episode)
        })
    }

    private func makePodcastItem(
        _ podcastRow: CarPlayPodcastRow,
        row: CarPlayListRow,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> (item: CPListItem, artworkTarget: CarPlayArtworkTarget?) {
        let artwork = artwork(for: podcastRow.artworkURL, cacheKind: .show)
        let item = CPListItem(
            text: podcastRow.title,
            detailText: nil,
            image: artwork.image,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = handler(for: row, onSelect: onSelect)
        return (item, artwork.pendingURL.map { url in
            CarPlayArtworkTarget(item: item, artworkURL: url, cacheKind: .show)
        })
    }

    private func makePlaylistItem(
        _ playlistRow: CarPlayPlaylistRow,
        row: CarPlayListRow,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> (item: CPListItem, artworkTarget: CarPlayArtworkTarget?) {
        let artwork = artwork(for: playlistRow.artworkURL, cacheKind: .show)
        // A symbol row has no URL to patch; an unknown stored symbol falls back
        // to the playlist glyph so the slot is never empty.
        let image = playlistRow.artworkURL == nil
            ? UIImage(systemName: playlistRow.symbolName ?? "music.note.list") ?? UIImage(systemName: "music.note.list")
            : artwork.image
        let item = CPListItem(
            text: playlistRow.title,
            detailText: playlistRow.detailText,
            image: image,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = handler(for: row, onSelect: onSelect)
        return (item, artwork.pendingURL.map { url in
            CarPlayArtworkTarget(item: item, artworkURL: url, cacheKind: .show)
        })
    }

    private func makeItem(
        text: String,
        image: UIImage? = nil,
        row: CarPlayListRow,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> CPListItem {
        let item = CPListItem(
            text: text,
            detailText: nil,
            image: image,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = handler(for: row, onSelect: onSelect)
        return item
    }

    private func handler(
        for row: CarPlayListRow,
        onSelect: @escaping (CarPlayListRow) -> Void
    ) -> (any CPSelectableListItem, @escaping () -> Void) -> Void {
        { _, completion in
            // CarPlay times out slow handlers, so the row is released before any
            // work starts.
            completion()
            onSelect(row)
        }
    }

    /// First paint comes from whatever is already in memory — a differently
    /// sized cache entry is better than a blank row. Anything not already at the
    /// car's exact size is reported for the staggered patch pass.
    private func artwork(
        for artworkURL: String?,
        cacheKind: ArtworkCacheKind
    ) -> (image: UIImage?, pendingURL: URL?) {
        guard let artworkURL, let url = URL(string: artworkURL) else {
            return (nil, nil)
        }

        let request = ArtworkRequest(url: url, targetPixelSize: artworkSizing.pixelSize)
        if let exactImage = ArtworkLoader.shared.cachedImage(for: request) {
            return (artworkSizing.matchingCarScale(exactImage), nil)
        }

        let approximateImage = ArtworkLoader.shared.bestCachedImage(for: request)
        return (approximateImage.map(artworkSizing.matchingCarScale), url)
    }
}
