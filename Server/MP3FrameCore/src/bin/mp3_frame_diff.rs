//! Local-only differential CLI.
//!
//! Walks an MP3 with the production core and prints the probe fields, chunk
//! spans and per-chunk SHA-256 as JSON so they can be compared against the
//! pinned ffmpeg 9 container's `-ss`/`-t` stream-copy output. Every run also
//! recomputes each chunk's hash from the materialized span bytes and exits
//! non-zero if the walker's streamed hash diverges, so every fixture doubles
//! as a streaming-vs-blob differential. Not shipped in any Worker:
//! `RemoteTranscriptionWorker` links the library only.
//!
//! Usage: `mp3-frame-diff <file.mp3> [range-bytes]`

use std::io::Read;

use opencast_mp3_frame_core::sha256;
use opencast_mp3_frame_core::tags::{scan_tail, TAIL_PROBE_BYTES};
use opencast_mp3_frame_core::{Mp3Walker, WalkOptions};

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(path) = args.next() else {
        eprintln!("usage: mp3-frame-diff <file.mp3> [range-bytes]");
        std::process::exit(2);
    };
    let range_bytes: usize = args
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(4 * 1024 * 1024);

    let mut bytes = Vec::new();
    std::fs::File::open(&path)
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .unwrap_or_else(|error| {
            eprintln!("read {path}: {error}");
            std::process::exit(2);
        });

    let object_len = bytes.len() as u64;
    let tail_start = object_len.saturating_sub(TAIL_PROBE_BYTES) as usize;
    let tail = scan_tail(object_len, &bytes[tail_start..]);

    let mut walker = Mp3Walker::new(WalkOptions::new(object_len, tail.audio_end));
    let mut peak_buffered = 0usize;
    // Wall time of the walk itself (file read and JSON excluded), so the
    // local differential gate also catches cost regressions: the 2026-08-19
    // per-frame trim made an 8 MiB-range walk quadratic and this line would
    // have shown seconds-per-megabyte instead of milliseconds.
    let walk_started = std::time::Instant::now();
    for range in bytes.chunks(range_bytes.max(1)) {
        if let Err(error) = walker.feed(range) {
            println!("{{\"error\":\"{}\"}}", error.reason());
            std::process::exit(1);
        }
        peak_buffered = peak_buffered.max(walker.buffered_bytes());
    }
    let trim_bytes_moved = walker.trim_bytes_moved();
    let result = match walker.finish() {
        Ok(result) => result,
        Err(error) => {
            println!("{{\"error\":\"{}\"}}", error.reason());
            std::process::exit(1);
        }
    };
    let walk_elapsed = walk_started.elapsed();
    eprintln!(
        "walk: {:.3}s range_bytes={} peak_buffered_bytes={} trim_bytes_moved={}",
        walk_elapsed.as_secs_f64(),
        range_bytes,
        peak_buffered,
        trim_bytes_moved
    );

    let mut out = String::new();
    out.push('{');
    field(
        &mut out,
        "source_sha256",
        &quoted(&sha256::hex(&sha256::digest(&bytes))),
    );
    field(&mut out, "object_len", &object_len.to_string());
    field(&mut out, "audio_end", &result.audio_end.to_string());
    field(
        &mut out,
        "leading_tag_bytes",
        &result.leading_tag_bytes.to_string(),
    );
    field(
        &mut out,
        "trailing_tag_bytes",
        &result.trailing_tag_bytes.to_string(),
    );
    field(
        &mut out,
        "first_audio_offset",
        &result.first_audio_offset.to_string(),
    );
    field(&mut out, "audio_frames", &result.audio_frames.to_string());
    field(&mut out, "sample_rate", &result.sample_rate.to_string());
    field(&mut out, "channels", &result.channels.to_string());
    field(
        &mut out,
        "samples_per_frame",
        &result.samples_per_frame.to_string(),
    );
    field(&mut out, "start_ticks", &result.start_ticks.to_string());
    field(&mut out, "walked_ticks", &result.walked_ticks.to_string());
    field(
        &mut out,
        "canonical_micros",
        &result.canonical_micros.to_string(),
    );
    field(
        &mut out,
        "canonical_seconds",
        &format!("{:.3}", result.canonical_seconds()),
    );
    field(
        &mut out,
        "variable_bitrate",
        &result.variable_bitrate.to_string(),
    );
    field(&mut out, "resync_events", &result.resync_events.to_string());
    field(&mut out, "junk_bytes", &result.junk_bytes.to_string());
    field(
        &mut out,
        "truncated_tail_bytes",
        &result.truncated_tail_bytes.to_string(),
    );
    field(&mut out, "peak_buffered_bytes", &peak_buffered.to_string());
    field(&mut out, "trim_bytes_moved", &trim_bytes_moved.to_string());
    field(
        &mut out,
        "walk_elapsed_seconds",
        &format!("{:.3}", walk_elapsed.as_secs_f64()),
    );
    field(
        &mut out,
        "vbr_kind",
        &quoted(&match result.vbr.as_ref().map(|tag| tag.kind) {
            Some(kind) => format!("{kind:?}"),
            None => "none".to_string(),
        }),
    );
    field(
        &mut out,
        "vbr_frames",
        &result.vbr.as_ref().map_or(0, |tag| tag.frames).to_string(),
    );

    out.push_str("\"chunks\":[");
    let mut streamed_divergence = false;
    for (position, chunk) in result.chunks.iter().enumerate() {
        if position > 0 {
            out.push(',');
        }
        let mut blob = Vec::with_capacity(chunk.byte_count as usize);
        for span in &chunk.spans {
            blob.extend_from_slice(&bytes[span.start as usize..span.end as usize]);
        }
        let blob_sha = sha256::hex(&sha256::digest(&blob));
        let streamed_sha = chunk.sha256_hex();
        if blob_sha != streamed_sha {
            eprintln!(
                "chunk {}: streamed sha {} != blob sha {}",
                chunk.index, streamed_sha, blob_sha
            );
            streamed_divergence = true;
        }
        out.push('{');
        field(&mut out, "index", &chunk.index.to_string());
        field(
            &mut out,
            "requested_start_seconds",
            &format!("{:.3}", chunk.requested_start_seconds()),
        );
        field(
            &mut out,
            "actual_duration_seconds",
            &format!("{:.3}", chunk.actual_duration_seconds()),
        );
        field(&mut out, "byte_count", &chunk.byte_count.to_string());
        field(&mut out, "frames", &chunk.frames.to_string());
        field(
            &mut out,
            "first_pts_ticks",
            &chunk.first_pts_ticks.to_string(),
        );
        field(&mut out, "source_offset", &chunk.spans[0].start.to_string());
        let spans: Vec<String> = chunk
            .spans
            .iter()
            .map(|span| format!("[{},{}]", span.start, span.end))
            .collect();
        field(&mut out, "spans", &format!("[{}]", spans.join(",")));
        field(&mut out, "streamed_sha256", &quoted(&streamed_sha));
        out.push_str(&format!("\"sha256\":{}", quoted(&blob_sha)));
        out.push('}');
    }
    out.push_str("]}");
    println!("{out}");
    if streamed_divergence {
        std::process::exit(1);
    }
}

fn field(out: &mut String, key: &str, value: &str) {
    out.push_str(&format!("\"{key}\":{value},"));
}

fn quoted(value: &str) -> String {
    format!("\"{value}\"")
}
