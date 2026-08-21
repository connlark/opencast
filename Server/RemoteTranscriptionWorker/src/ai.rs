//! Workers AI adapter (typed request/response per RUST_AI_BINDING_PROBE.md).
//! The binding's error surface is untyped JavaScript: Cloudflare codes like
//! `5006` survive only in error name/message text, so classification uses
//! sanitized message matching and fails closed on unknown errors.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
pub struct WhisperRequest {
    pub audio: String,
    pub task: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    pub vad_filter: bool,
    pub condition_on_previous_text: bool,
}

impl WhisperRequest {
    pub fn transcribe(audio_base64: String, language: Option<String>) -> Self {
        Self {
            audio: audio_base64,
            task: "transcribe",
            language,
            vad_filter: false,
            condition_on_previous_text: false,
        }
    }
}

/// The bakeoff/probe request settings hash: stable identity for provenance.
/// Computed over the canonical settings string, not per-request audio.
pub fn request_settings_sha256(model: &str, language: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    let settings = format!(
        "model={model}|task=transcribe|language={}|vad_filter=false|condition_on_previous_text=false",
        language.unwrap_or("auto")
    );
    hex::encode(Sha256::digest(settings.as_bytes()))
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WhisperWord {
    pub word: String,
    pub start: f64,
    pub end: f64,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WhisperSegment {
    pub start: f64,
    pub end: f64,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub words: Vec<WhisperWord>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WhisperTranscriptionInfo {
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub duration: Option<f64>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WhisperResponse {
    #[serde(default)]
    pub transcription_info: Option<WhisperTranscriptionInfo>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub segments: Vec<WhisperSegment>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl WhisperResponse {
    pub fn to_chunk_transcription(
        &self,
        requested_start_seconds: f64,
        valid_end_seconds: f64,
    ) -> crate::stitch::ChunkTranscription {
        crate::stitch::ChunkTranscription {
            requested_start_seconds,
            valid_end_seconds,
            segments: self
                .segments
                .iter()
                .map(|segment| crate::stitch::ModelSegment {
                    start: segment.start,
                    end: segment.end,
                    text: segment.text.clone(),
                    words: segment
                        .words
                        .iter()
                        .map(|word| crate::stitch::ModelWord {
                            text: word.word.clone(),
                            start: word.start,
                            end: word.end,
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiFailureClass {
    Retryable,
    Fatal,
}

/// Classify a sanitized binding error. Fails closed: anything unrecognized is
/// fatal so an unknown failure mode can never burn the retry budget blindly.
pub fn classify_ai_error(sanitized: &str) -> AiFailureClass {
    let lowered = sanitized.to_ascii_lowercase();
    const RETRYABLE_MARKERS: [&str; 12] = [
        "429",
        "rate limit",
        "ratelimited",
        "too many requests",
        "capacity",
        "overloaded",
        "timeout",
        "timed out",
        "network connection lost",
        "internal error",
        "service unavailable",
        "3040",
    ];
    if RETRYABLE_MARKERS
        .iter()
        .any(|marker| lowered.contains(marker))
    {
        AiFailureClass::Retryable
    } else {
        AiFailureClass::Fatal
    }
}

/// Keep error diagnostics content-free and bounded: no base64 payloads, no
/// long values, just the leading name/message text.
pub fn sanitize_ai_error(raw: &str) -> String {
    let mut sanitized: String = raw
        .chars()
        .filter(|character| !character.is_control())
        .take(300)
        .collect();
    // Long unbroken tokens are payload-ish; elide them.
    sanitized = sanitized
        .split(' ')
        .map(|token| if token.len() > 80 { "<elided>" } else { token })
        .collect::<Vec<_>>()
        .join(" ");
    sanitized
}

/// Test hooks carried in the job's language code (development lane, FAKE_AI
/// only — real AI calls never see these). Two grammars:
/// - legacy `fake-fail:<message>`: chunk 0 fails its first attempt.
/// - `fake:key=value;…[;fail=<index>:<first|always>:<message>]` with keys
///   `conc` (per-job concurrency override), `latency` (per-call fake AI
///   latency, milliseconds), and `mlat` (fake-media per-chunk write latency,
///   milliseconds — makes chunk production progressive so overlap is
///   observable). `fail` consumes the remainder of the string so messages
///   may contain any character.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FakeAiHooks {
    pub concurrency_override: Option<u32>,
    pub latency_ms: Option<u64>,
    pub media_chunk_latency_ms: Option<u64>,
    /// `sfail=1`: the first stitch pass fails just before settle, after the
    /// result object is durable — drives the stitch re-entry invariant test.
    pub settle_fail_once: bool,
    /// `rfail=N`: the first N credit-release attempts fail — drives the
    /// RTW-5 terminal-path release backstop tests.
    pub release_fail_count: Option<u32>,
    /// `strand=N` / `strand=<state>:N`: the first N alarm turns that find the
    /// record in an active-work state (optionally only `<state>`) delete
    /// their alarm and return without scheduling — the only deterministic way
    /// to leave an active state with no alarm, which drives the stranded-job
    /// repair tests (2026-08-19).
    pub strand: Option<FakeStrandRule>,
    pub failure: Option<FakeAiFailureRule>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FakeStrandRule {
    /// Restrict the hook to alarm turns entered in this state; `None` means
    /// any active-work state.
    pub state: Option<String>,
    pub count: u32,
}

impl FakeStrandRule {
    /// True when a turn entered in `state` (already known to be active work)
    /// should strand, given `stranded_so_far` turns already have.
    pub fn applies(&self, state: &str, stranded_so_far: u32) -> bool {
        stranded_so_far < self.count && self.state.as_deref().is_none_or(|only| only == state)
    }
}

impl FakeStrandRule {
    fn parse(value: &str) -> Option<Self> {
        match value.split_once(':') {
            Some((state, count)) => Some(Self {
                state: Some(state.to_string()),
                count: count.parse().ok()?,
            }),
            None => Some(Self {
                state: None,
                count: value.parse().ok()?,
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FakeAiFailureRule {
    pub chunk_index: u32,
    pub every_attempt: bool,
    pub message: String,
}

impl FakeAiFailureRule {
    pub fn applies(&self, chunk_index: u32, prior_failed_attempts: u32) -> bool {
        self.chunk_index == chunk_index && (self.every_attempt || prior_failed_attempts == 0)
    }
}

pub fn parse_fake_hooks(language_code: Option<&str>) -> FakeAiHooks {
    let mut hooks = FakeAiHooks::default();
    let Some(language_code) = language_code else {
        return hooks;
    };
    if let Some(message) = language_code.strip_prefix("fake-fail:") {
        hooks.failure = Some(FakeAiFailureRule {
            chunk_index: 0,
            every_attempt: false,
            message: message.to_string(),
        });
        return hooks;
    }
    let Some(mut rest) = language_code.strip_prefix("fake:") else {
        return hooks;
    };
    while !rest.is_empty() {
        if let Some(fail_spec) = rest.strip_prefix("fail=") {
            // fail consumes the remainder: <index>:<first|always>:<message>
            let mut parts = fail_spec.splitn(3, ':');
            let index = parts.next().and_then(|part| part.parse().ok());
            let mode = parts.next();
            let message = parts.next();
            if let (Some(chunk_index), Some(mode), Some(message)) = (index, mode, message) {
                hooks.failure = Some(FakeAiFailureRule {
                    chunk_index,
                    every_attempt: mode == "always",
                    message: message.to_string(),
                });
            }
            break;
        }
        let (segment, remainder) = match rest.split_once(';') {
            Some((segment, remainder)) => (segment, remainder),
            None => (rest, ""),
        };
        if let Some((key, value)) = segment.split_once('=') {
            match key {
                "conc" => hooks.concurrency_override = value.parse().ok(),
                "latency" => hooks.latency_ms = value.parse().ok(),
                "mlat" => hooks.media_chunk_latency_ms = value.parse().ok(),
                "sfail" => hooks.settle_fail_once = value == "1",
                "rfail" => hooks.release_fail_count = value.parse().ok(),
                "strand" => hooks.strand = FakeStrandRule::parse(value),
                _ => {}
            }
        }
        rest = remainder;
    }
    hooks
}

/// Deterministic fake response for workerd integration tests (FAKE_AI mode,
/// development lane only): three words per chunk with stable timings.
pub fn fake_whisper_response(chunk_index: u32, duration_seconds: f64) -> WhisperResponse {
    let words = ["remote", "transcription", &format!("chunk{chunk_index}")];
    let step = (duration_seconds.max(3.0) - 1.0) / words.len() as f64;
    let whisper_words: Vec<WhisperWord> = words
        .iter()
        .enumerate()
        .map(|(index, word)| WhisperWord {
            word: (*word).to_string(),
            start: 0.5 + step * index as f64,
            end: 0.5 + step * index as f64 + 0.4,
            extra: serde_json::Map::new(),
        })
        .collect();
    WhisperResponse {
        transcription_info: Some(WhisperTranscriptionInfo {
            language: Some("en".to_string()),
            duration: Some(duration_seconds),
            extra: serde_json::Map::new(),
        }),
        text: Some(words.join(" ")),
        segments: vec![WhisperSegment {
            start: 0.0,
            end: duration_seconds,
            text: words.join(" "),
            words: whisper_words,
            extra: serde_json::Map::new(),
        }],
        extra: serde_json::Map::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classification_fails_closed_on_validation_errors() {
        // Observed in the probe: AiError 5006 validation failure is fatal.
        assert_eq!(
            classify_ai_error("AiError: 5006: Error: required properties at '/' are 'audio'"),
            AiFailureClass::Fatal
        );
        assert_eq!(classify_ai_error("something novel"), AiFailureClass::Fatal);
        assert_eq!(classify_ai_error(""), AiFailureClass::Fatal);
    }

    #[test]
    fn classification_recognizes_retryable_markers() {
        for message in [
            "AiError: 429 Too Many Requests",
            "Error: model is overloaded",
            "fetch timed out",
            "AiError: 3040: capacity temporarily exceeded",
            "Internal error occurred",
        ] {
            assert_eq!(
                classify_ai_error(message),
                AiFailureClass::Retryable,
                "{message}"
            );
        }
    }

    #[test]
    fn sanitizer_elides_payload_tokens() {
        let long_token = "A".repeat(500);
        let sanitized = sanitize_ai_error(&format!("failed with {long_token}"));
        assert!(sanitized.contains("<elided>"));
        assert!(sanitized.len() < 350);
    }

    #[test]
    fn response_decodes_probe_shape_with_unknown_fields() {
        let json = serde_json::json!({
            "transcription_info": {"language": "en", "duration": 299.4245, "language_probability": 1.0},
            "text": "hello world",
            "word_count": 2,
            "usage": {"prompt_tokens": 1},
            "segments": [{
                "start": 0.0, "end": 2.0, "text": "hello world",
                "word_count": 2,
                "words": [
                    {"word": "hello", "start": 0.1, "end": 0.9},
                    {"word": "world", "start": 1.0, "end": 1.9}
                ]
            }],
            "vtt": "WEBVTT..."
        });
        let decoded: WhisperResponse = serde_json::from_value(json).expect("decodes");
        assert_eq!(decoded.segments.len(), 1);
        assert_eq!(decoded.segments[0].words.len(), 2);
        assert!(decoded.extra.contains_key("vtt"));
        assert!(decoded.segments[0].extra.contains_key("word_count"));
        let chunk = decoded.to_chunk_transcription(298.0, 598.0);
        assert_eq!(chunk.requested_start_seconds, 298.0);
        assert_eq!(chunk.valid_end_seconds, 598.0);
        assert_eq!(chunk.segments[0].words[0].text, "hello");
    }

    #[test]
    fn fake_hooks_parse_legacy_and_combined_grammars() {
        assert_eq!(parse_fake_hooks(None), FakeAiHooks::default());
        assert_eq!(parse_fake_hooks(Some("en")), FakeAiHooks::default());

        let legacy = parse_fake_hooks(Some("fake-fail:429 rate limited"));
        let rule = legacy.failure.expect("legacy rule");
        assert_eq!(rule.chunk_index, 0);
        assert!(!rule.every_attempt);
        assert_eq!(rule.message, "429 rate limited");
        assert!(rule.applies(0, 0));
        assert!(!rule.applies(0, 1));
        assert!(!rule.applies(1, 0));

        let combined = parse_fake_hooks(Some(
            "fake:conc=1;latency=2000;mlat=700;fail=2:always:AiError: 5006: bad; input",
        ));
        assert_eq!(combined.concurrency_override, Some(1));
        assert_eq!(combined.latency_ms, Some(2000));
        assert_eq!(combined.media_chunk_latency_ms, Some(700));
        let rule = combined.failure.expect("combined rule");
        assert_eq!(rule.chunk_index, 2);
        assert!(rule.every_attempt);
        // The fail spec consumed everything after the mode, semicolons included.
        assert_eq!(rule.message, "AiError: 5006: bad; input");
        assert!(rule.applies(2, 5));

        let latency_only = parse_fake_hooks(Some("fake:latency=1500"));
        assert_eq!(latency_only.latency_ms, Some(1500));
        assert_eq!(latency_only.failure, None);

        let settle_fail = parse_fake_hooks(Some("fake:sfail=1"));
        assert!(settle_fail.settle_fail_once);
        assert!(!parse_fake_hooks(Some("fake:sfail=0")).settle_fail_once);
        assert!(!latency_only.settle_fail_once);

        let release_fail = parse_fake_hooks(Some("fake:rfail=2"));
        assert_eq!(release_fail.release_fail_count, Some(2));
        assert_eq!(latency_only.release_fail_count, None);

        let strand_any = parse_fake_hooks(Some("fake:strand=1"))
            .strand
            .expect("strand");
        assert_eq!(strand_any.state, None);
        assert_eq!(strand_any.count, 1);
        assert!(strand_any.applies("created", 0));
        assert!(strand_any.applies("transcribing", 0));
        assert!(!strand_any.applies("created", 1));

        let strand_in = parse_fake_hooks(Some("fake:strand=transcribing:2;conc=1"))
            .strand
            .expect("strand");
        assert_eq!(strand_in.state.as_deref(), Some("transcribing"));
        assert_eq!(strand_in.count, 2);
        assert!(strand_in.applies("transcribing", 1));
        assert!(!strand_in.applies("transcribing", 2));
        assert!(!strand_in.applies("created", 0));
        assert_eq!(parse_fake_hooks(Some("fake:strand=x")).strand, None);
        assert_eq!(latency_only.strand, None);
    }

    #[test]
    fn request_settings_hash_is_stable() {
        let a = request_settings_sha256("@cf/openai/whisper-large-v3-turbo", Some("en"));
        let b = request_settings_sha256("@cf/openai/whisper-large-v3-turbo", Some("en"));
        let c = request_settings_sha256("@cf/openai/whisper-large-v3-turbo", None);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }
}
