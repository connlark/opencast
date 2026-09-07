use super::{parse_rss, scan::scan_rss, RSSParseError};
use crate::{poll_decisions, poll_scheduling, storage::FeedPollRow};
use futures_util::FutureExt;
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, ReadBuf};

struct Chunks<'a> {
    bytes: &'a [u8],
    size: usize,
}
impl AsyncRead for Chunks<'_> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        target: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let count = self.bytes.len().min(self.size).min(target.remaining());
        target.put_slice(&self.bytes[..count]);
        self.bytes = &self.bytes[count..];
        Poll::Ready(Ok(()))
    }
}

pub(super) fn row(checkpoint: Option<String>) -> FeedPollRow {
    FeedPollRow {
        feed_url: "https://example.com/feed.xml".into(),
        source_url: "https://example.com/feed.xml".into(),
        etag: None,
        last_modified: None,
        latest_episode_id: checkpoint,
        latest_episode_title: None,
        latest_episode_published_at: None,
        baseline_established_at: Some(0),
        consecutive_failures: 0,
        publish_cadence_seconds: None,
    }
}

fn compare(xml: &str, chunk: usize) {
    let materialized = parse_rss(xml, &row(None).feed_url).expect("fixture parses");
    let checkpoints = [
        None,
        Some("missing".into()),
        materialized.episodes.first().map(|e| e.id.clone()),
        materialized.episodes.last().map(|e| e.id.clone()),
    ];
    for checkpoint in checkpoints {
        let feed = row(checkpoint);
        let scanned = scan_rss(
            Chunks {
                bytes: xml.as_bytes(),
                size: chunk,
            },
            &feed,
        )
        .now_or_never()
        .unwrap()
        .unwrap();
        assert_eq!(scanned.title, materialized.title);
        assert_eq!(scanned.website_url, materialized.website_url);
        assert_eq!(scanned.artwork_url, materialized.artwork_url);
        assert_eq!(scanned.latest.id, materialized.episodes[0].id);
        assert_eq!(scanned.latest.title, materialized.episodes[0].title);
        assert_eq!(
            scanned.latest.published_at,
            materialized.episodes[0].published_at
        );
        let expected = poll_decisions::episodes_to_notify(&feed, &materialized)
            .into_iter()
            .cloned()
            .collect::<Vec<_>>();
        assert_eq!(scanned.notifications.len(), expected.len());
        for (actual, original) in scanned.notifications.iter().zip(expected) {
            let fingerprint = crate::feed_identity::episode_notification_fingerprint(
                crate::feed_identity::EpisodeNotificationFingerprintInput {
                    title: &original.title,
                    guid: original.guid.as_deref(),
                    audio_url: original.audio_url.as_deref(),
                    duration_seconds: original.duration_seconds,
                    summary: original.summary.as_deref(),
                    show_notes_html: original.show_notes_html.as_deref(),
                    episode_id: &original.id,
                },
            );
            assert_eq!(actual.fingerprint, fingerprint);
            assert_eq!(actual.episode.id, original.id);
            assert_eq!(actual.episode.title, original.title);
            assert_eq!(actual.episode.summary, original.summary);
            assert_eq!(actual.episode.show_notes_html, original.show_notes_html);
            assert_eq!(actual.episode.duration_seconds, original.duration_seconds);
        }
        let mut dates = materialized
            .episodes
            .iter()
            .filter_map(|e| e.published_at)
            .collect::<Vec<_>>();
        assert_eq!(
            scanned.publish_cadence_seconds,
            poll_scheduling::publish_cadence_seconds(&mut dates)
        );
        assert!(scanned.notifications.len() <= 3);
    }
}

#[test]
fn chunk_boundaries_preserve_notifications_and_metadata() {
    let fixture = include_str!(
        "../../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/fallbacks.xml"
    );
    for chunk in [1, 2, 3, 7, 64, 65536] {
        compare(fixture, chunk);
    }
    let entity_fixture = "<rss><channel><title>A &amp; B</title><item><title>Caf&#233; 🧪</title><guid>1</guid><pubDate>2026-09-05T00:00:00Z</pubDate><description><![CDATA[<p>Café 🧪</p>]]> &amp; &nbsp; &#60;</description></item><item><guid>2</guid><title>Old</title><pubDate>2025-01-01T00:00:00Z</pubDate></item></channel></rss>";
    for chunk in [1, 3, 17] {
        compare(entity_fixture, chunk);
    }
}

#[test]
fn long_notification_text_preserves_fingerprint_boundaries() {
    for tail in [" x", "    x", "       ", "🧪&amp;after", "🧪🧪after"] {
        let notes = format!("{}{}", "a".repeat(16 * 1024 - 1), tail);
        let xml = format!("<rss><channel><item><guid>1</guid><title>One</title><description>{notes}</description></item></channel></rss>");
        compare(&xml, 7);
    }
}

#[test]
fn deep_checkpoint_and_raw_item_limit() {
    let mut xml = "<rss><channel><title>Large</title>".to_string();
    for index in 0..100_000 {
        xml.push_str(&format!("<item><guid>{index}</guid><title>Episode {index}</title><pubDate>2026-09-05T00:00:00Z</pubDate></item>"));
    }
    xml.push_str("</channel></rss>");
    let feed = row(Some(crate::feed_identity::episode_id(
        &row(None).feed_url,
        Some("99999"),
        None,
        "",
        None,
    )));
    let scanned = scan_rss(xml.as_bytes(), &feed)
        .now_or_never()
        .unwrap()
        .unwrap();
    assert_eq!(scanned.item_count, 100_000);
    assert!(scanned.checkpoint_found);
    assert_eq!(scanned.notifications.len(), 3);
    xml = xml.replace("</channel>", "<item><guid>extra</guid></item></channel>");
    assert!(matches!(
        scan_rss(xml.as_bytes(), &feed).now_or_never().unwrap(),
        Err(RSSParseError::TooManyFeedItems)
    ));
}

#[test]
fn incomplete_documents_never_produce_notification_decisions() {
    for xml in [
        "<rss><channel><item><guid>1</guid></item>",
        "<rss><channel><item><guid>1</guid></item></channel></rss><rss/>",
        "<html><item><guid>1</guid></item></html>",
        "garbage<rss><channel><item><guid>1</guid></item></channel></rss>",
        "<rss><channel><item><guid>1</guid></item></channel></rss>garbage",
    ] {
        assert!(scan_rss(xml.as_bytes(), &row(Some("old".into())))
            .now_or_never()
            .unwrap()
            .is_err());
    }
}

#[test]
fn empty_elements_obey_the_same_depth_limit() {
    for depth in [50, 51] {
        let xml = format!(
            "<rss><channel><item><guid>1</guid>{}<empty/>{}</item></channel></rss>",
            "<nested>".repeat(depth - 4),
            "</nested>".repeat(depth - 4)
        );
        let result = scan_rss(xml.as_bytes(), &row(None)).now_or_never().unwrap();
        if depth == 50 {
            assert!(result.is_ok());
        } else {
            assert!(matches!(
                result,
                Err(RSSParseError::ResourceLimit("feed_depth_limit"))
            ));
        }
    }
}

#[test]
fn decoded_and_text_budgets_accept_exact_limits() {
    use crate::feed_resource as limits;
    let prefix = b"<rss><channel><item><guid>1</guid></item>";
    let suffix = b"</channel></rss>";
    let comment = format!("<!--{}-->", "x".repeat(65536 - 7));
    for mib in [8, 12, 64, 128] {
        for excess in [0, 1] {
            let length = mib * 1024 * 1024 + excess;
            let mut xml = Vec::with_capacity(length);
            xml.extend(prefix);
            while length - xml.len() - suffix.len() >= comment.len() {
                xml.extend(comment.as_bytes());
            }
            xml.resize(length - suffix.len(), b' ');
            xml.extend(suffix);
            let result = scan_rss(xml.as_slice(), &row(None)).now_or_never().unwrap();
            assert_eq!(result.is_ok(), length <= limits::MAX_DECODED_BYTES);
            if length > limits::MAX_DECODED_BYTES {
                assert!(matches!(
                    result,
                    Err(RSSParseError::ResourceLimit("oversized_body"))
                ));
            }
        }
    }
    for excess in [0, 1] {
        let xml = format!("<rss><channel><item><guid>1</guid><description><![CDATA[{}]]></description></item></channel></rss>",
            "x".repeat(limits::MAX_FIELD_BYTES + excess));
        let result = scan_rss(xml.as_bytes(), &row(None)).now_or_never().unwrap();
        assert_eq!(result.is_ok(), excess == 0);
        if excess == 1 {
            assert!(matches!(
                result,
                Err(RSSParseError::ResourceLimit("feed_field_limit"))
            ));
        }
        let xml = format!("<rss><channel><item><guid>1</guid><description>{}</description><content:encoded>{}</content:encoded></item></channel></rss>",
            "x".repeat(8 * 1024 * 1024), "y".repeat(8 * 1024 * 1024 - 1 + excess));
        let result = scan_rss(xml.as_bytes(), &row(None)).now_or_never().unwrap();
        assert_eq!(result.is_ok(), excess == 0);
        if excess == 1 {
            assert!(matches!(
                result,
                Err(RSSParseError::ResourceLimit("feed_item_text_limit"))
            ));
        }
    }
}

#[test]
fn pinned_large_captures_match_existing_decisions() {
    if std::env::var("OPENCAST_LARGE_FEED_CAPTURES").as_deref() != Ok("1") {
        return;
    }
    for name in ["herd", "greenfield", "eofire", "changelog"] {
        let xml =
            std::fs::read_to_string(format!("/private/tmp/opencast-feed-research-{name}.xml"))
                .unwrap();
        compare(&xml, 65536);
    }
}
