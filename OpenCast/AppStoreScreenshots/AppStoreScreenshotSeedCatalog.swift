#if DEBUG
import Foundation

/// Twelve synthetic shows for the App Store set. The Library sorts by title,
/// so the six new covers carry titles that sort ahead of the six older ones:
/// the iPhone list shows only the new art and the iPad grid puts the older
/// covers on its last rows.
enum AppStoreScreenshotSeedCatalog {
    static let primaryFeedURL = "https://screenshots.opencast.example/orbit-report.xml"
    static let primaryEpisodeID = "app-store-orbit-report-episode-1"
    /// The episode shown mid-pass on the pipeline card.
    static let pipelineEpisodeID = "app-store-orbit-report-episode-3"
    static let primaryPodcastTitle = "Orbit Report"
    static let primaryEpisodeTitle = "What the New Telescope Saw First"
    static let primaryEpisodeSummary = "A brand-new mirror opens its eye on a boring patch of sky, and a faint streak in the corner steals the night."
    static let primaryEpisodeDuration: TimeInterval = 2_940
    static let primaryArtworkName = "orbit-report"

    /// Relative dates keep the library rows reading "Refreshed today" and the
    /// Inbox grouping under Today, whatever day the lane runs.
    static let referenceDate = Date.now

    static let podcasts: [AppStoreScreenshotSeedPodcast] = [
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/greenhouse-hours.xml",
            title: "Greenhouse Hours",
            author: "Ines Marlow",
            summary: "Gardening for people with more enthusiasm than square footage: seeds, soil, and what actually grows on a windowsill.",
            websiteURL: "https://screenshots.opencast.example/greenhouse-hours",
            artworkName: "greenhouse-hours",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-greenhouse-hours-episode-1",
                    title: "Tomatoes in Low Light",
                    summary: "A north-facing balcony, three varieties, and one honest season of results.",
                    showNotesHTML: "<p>Which varieties cope with a shaded balcony, and which ones only pretend to.</p>",
                    publishedAt: date(daysAgo: 3),
                    duration: 2_280,
                    position: nil,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-greenhouse-hours-episode-2",
                    title: "What to Plant in September",
                    summary: "Garlic, broad beans, and the salad leaves that shrug off the first frost.",
                    showNotesHTML: "<p>Autumn sowing for small spaces.</p>",
                    publishedAt: date(daysAgo: 10),
                    duration: 1_740,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/half-time.xml",
            title: "Half-Time",
            author: "Jonah Brecht",
            summary: "Sport at the quiet moments: empty stadiums, second halves, and what a match looks like from the tunnel.",
            websiteURL: "https://screenshots.opencast.example/half-time",
            artworkName: "half-time",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-half-time-episode-1",
                    title: "The Second Half Nobody Watched",
                    summary: "A dead rubber on a wet Tuesday, and the forty-five minutes that quietly decided a season.",
                    showNotesHTML: "<p>Why the least-watched half of the year mattered most.</p>",
                    publishedAt: date(daysAgo: 4),
                    duration: 2_640,
                    position: nil,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-half-time-episode-2",
                    title: "Referee, Whistle, Fog",
                    summary: "An official's own account of the match nobody could see from the stands.",
                    showNotesHTML: "<p>Officiating a fixture in fog, told from the middle of the pitch.</p>",
                    publishedAt: date(daysAgo: 11),
                    duration: 2_160,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/kitchen-table.xml",
            title: "Kitchen Table",
            author: "Rosa Aldana",
            summary: "Food and money at the same table: what dinner costs, what it is worth, and the small habits that keep both honest.",
            websiteURL: "https://screenshots.opencast.example/kitchen-table",
            artworkName: "kitchen-table",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-kitchen-table-episode-1",
                    title: "The Real Price of a Loaf",
                    summary: "Flour, time, and an oven bill: what a home-baked loaf actually costs against the bakery.",
                    showNotesHTML: "<p>A receipt-level look at bread, with the oven included.</p>",
                    publishedAt: date(daysAgo: 1),
                    duration: 2_040,
                    position: nil,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-kitchen-table-episode-2",
                    title: "Grocery Math for Two",
                    summary: "A two-person shop, one calculator, and the habits that stopped the weekly total creeping up.",
                    showNotesHTML: "<p>Shopping for two without a spreadsheet.</p>",
                    publishedAt: date(daysAgo: 9),
                    duration: 2_460,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/long-way-round.xml",
            title: "Long Way Round",
            author: "Callum Reyes",
            summary: "Slow travel by bicycle, ferry, and the occasional wrong turn. Stories from the roads that never make the fast map.",
            websiteURL: "https://screenshots.opencast.example/long-way-round",
            artworkName: "long-way-round",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-long-way-round-episode-1",
                    title: "A Coast Road in the Fog",
                    summary: "Ninety kilometres of cliff road with a folded map and no view, and why it was the best day of the trip.",
                    showNotesHTML: "<p>A day on the coast road when the sea never showed up.</p>",
                    publishedAt: date(daysAgo: 2),
                    duration: 3_120,
                    position: nil,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-long-way-round-episode-2",
                    title: "Ferry Timetables and Other Fictions",
                    summary: "Island crossings, missed sailings, and the harbour café that runs on its own clock.",
                    showNotesHTML: "<p>Travelling by ferry when the timetable is more of a suggestion.</p>",
                    publishedAt: date(daysAgo: 14),
                    duration: 2_820,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: primaryFeedURL,
            title: primaryPodcastTitle,
            author: "Dana Whitlock",
            summary: "Space news for people who stay up late: new telescopes, old starlight, and what the data actually says.",
            websiteURL: "https://screenshots.opencast.example/orbit-report",
            artworkName: primaryArtworkName,
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: primaryEpisodeID,
                    title: primaryEpisodeTitle,
                    summary: primaryEpisodeSummary,
                    showNotesHTML: """
                    <p>This episode follows a new survey telescope's opening night from the first exposure to a provisional designation.</p>
                    <p>Chapters include pointing at an ordinary star field on purpose, the streak in the corner, improvising a follow-up plan, and what the survey will do for the next ten years.</p>
                    """,
                    publishedAt: date(daysAgo: 0),
                    duration: primaryEpisodeDuration,
                    position: 92,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-orbit-report-episode-2",
                    title: "Why Every Comet Is a Surprise",
                    summary: "Comets keep breaking the forecasts. A look at why brightness predictions fail and why that is the fun part.",
                    showNotesHTML: "<p>Brightness forecasts, outbursts, and the comets that ignored both.</p>",
                    publishedAt: date(daysAgo: 5),
                    duration: 2_280,
                    position: 2_210,
                    isPlayed: true
                ),
                AppStoreScreenshotSeedEpisode(
                    id: pipelineEpisodeID,
                    title: "The Quiet Season on the Sun",
                    summary: "Solar minimum is not boring: what the Sun does when it looks like it is doing nothing.",
                    showNotesHTML: "<p>Sunspot counts, the solar wind, and the quiet years between cycles.</p>",
                    publishedAt: date(daysAgo: 12),
                    duration: 2_940,
                    position: nil,
                    isPlayed: false
                )
            ]
        ),
        AppStoreScreenshotSeedPodcast(
            id: "https://screenshots.opencast.example/paper-lanterns.xml",
            title: "Paper Lanterns",
            author: "Mei Okafor",
            summary: "Short fiction read aloud, one lantern at a time. Original stories and old favorites, told slowly.",
            websiteURL: "https://screenshots.opencast.example/paper-lanterns",
            artworkName: "paper-lanterns",
            episodes: [
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-paper-lanterns-episode-1",
                    title: "The Light Under the Bridge",
                    summary: "A night-market story about a lantern maker, a stubborn kettle, and a promise kept a year late.",
                    showNotesHTML: "<p>An original story, read in one sitting.</p>",
                    publishedAt: date(daysAgo: 1),
                    duration: 1_860,
                    position: nil,
                    isPlayed: false
                ),
                AppStoreScreenshotSeedEpisode(
                    id: "app-store-paper-lanterns-episode-2",
                    title: "The Kettle That Wouldn't Boil",
                    summary: "A small story about patience, told from the back of a tea stall after closing.",
                    showNotesHTML: "<p>A short story for the end of the day.</p>",
                    publishedAt: date(daysAgo: 8),
                    duration: 1_620,
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
            title: "The Archive Hour",
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
            id: "https://screenshots.opencast.example/city-frequency.xml",
            title: "Urban Frequency",
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
            id: "https://screenshots.opencast.example/night-mode-notes.xml",
            title: "Weeknight Notes",
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
        referenceDate.addingTimeInterval(-daysAgo * 86_400)
    }
}
#endif
