#if DEBUG
import Foundation

enum AppStoreScreenshotSeedCatalog {
    static let primaryFeedURL = "https://screenshots.opencast.example/signal-path.xml"
    static let primaryEpisodeID = "app-store-signal-path-episode-1"

    static let podcasts: [AppStoreScreenshotSeedPodcast] = [
        AppStoreScreenshotSeedPodcast(
            id: primaryFeedURL,
            title: "Signal Path",
            author: "Marin Vale",
            summary: "Deep dives into the tiny decisions behind reliable software, clear diagnostics, and calmer releases.",
            websiteURL: "https://screenshots.opencast.example/signal-path",
            artworkName: "signal-path",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: primaryEpisodeID,
                    title: "Tracing the Bug That Only Appeared at Night",
                    summary: "A concise investigation into the logs, human assumptions, and timing clues that finally made a stubborn production issue reproducible.",
                    showNotesHTML: """
                    <p>This episode follows a late-night debugging session from first report to final fix.</p>
                    <p>Chapters include reproducing the failure, reading the wrong logs, narrowing the timing window, and leaving better diagnostics behind.</p>
                    """,
                    publishedAt: date(daysAgo: 0),
                    duration: 2_940,
                    position: 92,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-signal-path-episode-2",
                    title: "Designing Alerts People Actually Read",
                    summary: "A practical pass through signal, severity, and wording for app teams that want fewer noisy notifications.",
                    showNotesHTML: "<p>A practical guide to incident alerts that preserve attention.</p>",
                    publishedAt: date(daysAgo: 5),
                    duration: 2_280,
                    position: 2_210,
                    isPlayed: true
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-signal-path-episode-3",
                    title: "The Release Checklist That Paid for Itself",
                    summary: "Small habits for shipping with confidence without turning release day into a ceremony.",
                    showNotesHTML: "<p>Release notes, rollout windows, and the small checks worth automating.</p>",
                    publishedAt: date(daysAgo: 12),
                    duration: 2_520,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/quiet-desk.xml",
            title: "Quiet Desk",
            author: "Nia Calder",
            summary: "A focused show about notebooks, attention, and the routines that make creative work easier to return to.",
            websiteURL: "https://screenshots.opencast.example/quiet-desk",
            artworkName: "quiet-desk",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-quiet-desk-episode-1",
                    title: "A Better Morning Review",
                    summary: "Build a short review that catches the important things without becoming another project.",
                    showNotesHTML: "<p>A focused routine for notes, priorities, and clean starts.</p>",
                    publishedAt: date(daysAgo: 1),
                    duration: 1_860,
                    position: 540,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-quiet-desk-episode-2",
                    title: "Writing Down the Next Step",
                    summary: "Why a single clear next action keeps interrupted work from going stale.",
                    showNotesHTML: "<p>Examples for notes that help tomorrow's version of you restart quickly.</p>",
                    publishedAt: date(daysAgo: 8),
                    duration: 1_680,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/city-frequency.xml",
            title: "City Frequency",
            author: "Theo Brant",
            summary: "Stories about streets, transit, maps, architecture, and the signals that shape public life.",
            websiteURL: "https://screenshots.opencast.example/city-frequency",
            artworkName: "city-frequency",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-city-frequency-episode-1",
                    title: "The Map Under the Morning Commute",
                    summary: "How old station names, new routes, and small design choices change a city's daily rhythm.",
                    showNotesHTML: "<p>Transit maps, station history, and the design language of movement.</p>",
                    publishedAt: date(daysAgo: 2),
                    duration: 2_760,
                    position: nil,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-city-frequency-episode-2",
                    title: "Signals at the Crosswalk",
                    summary: "A close look at timing, signage, and the quiet choreography of crowded intersections.",
                    showNotesHTML: "<p>Street design through the details people notice only when it fails.</p>",
                    publishedAt: date(daysAgo: 15),
                    duration: 2_340,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/sound-lab-weekly.xml",
            title: "Sound Lab Weekly",
            author: "Mira Chen",
            summary: "A practical audio show about spoken-word production, intelligibility, levels, and listening tests.",
            websiteURL: "https://screenshots.opencast.example/sound-lab-weekly",
            artworkName: "sound-lab-weekly",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-sound-lab-episode-1",
                    title: "Making Voices Easier to Hear",
                    summary: "A plain-language tour of EQ, loudness, compression, and when less processing is the better choice.",
                    showNotesHTML: "<p>How spoken-word mixes become clearer without getting harsh.</p>",
                    publishedAt: date(daysAgo: 3),
                    duration: 2_160,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/archive-hour.xml",
            title: "Archive Hour",
            author: "Lena Soto",
            summary: "Documentary stories built from letters, timelines, oral history, and careful research.",
            websiteURL: "https://screenshots.opencast.example/archive-hour",
            artworkName: "archive-hour",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-archive-hour-episode-1",
                    title: "The Missing Index Card",
                    summary: "A research trail that starts with one mislabeled box and ends with a clearer story.",
                    showNotesHTML: "<p>Archival research, source notes, and what survives in the margins.</p>",
                    publishedAt: date(daysAgo: 4),
                    duration: 3_180,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/release-window.xml",
            title: "Release Window",
            author: "Priya Shah",
            summary: "Short conversations about small teams shipping software without drama.",
            websiteURL: "https://screenshots.opencast.example/release-window",
            artworkName: "release-window",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-release-window-episode-1",
                    title: "Feature Flags Without Fear",
                    summary: "A grounded approach to rollout controls, owner handoffs, and knowing when to remove the flag.",
                    showNotesHTML: "<p>Rollout controls for teams that prefer boring launches.</p>",
                    publishedAt: date(daysAgo: 6),
                    duration: 1_980,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/night-mode-notes.xml",
            title: "Night Mode Notes",
            author: "Jules Kwan",
            summary: "Late-night field recordings, short essays, and the small systems that keep creative projects moving.",
            websiteURL: "https://screenshots.opencast.example/night-mode-notes",
            artworkName: "night-mode-notes",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-night-mode-episode-1",
                    title: "Index Cards for Big Ideas",
                    summary: "How a tiny capture system can make a large project feel less scattered.",
                    showNotesHTML: "<p>Capturing rough thoughts without turning them into admin work.</p>",
                    publishedAt: date(daysAgo: 7),
                    duration: 1_740,
                    position: nil,
                    isPlayed: false
                )
            ]
        )
    ]

    private static func date(daysAgo: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_779_811_200 - daysAgo * 86_400)
    }
}
#endif
