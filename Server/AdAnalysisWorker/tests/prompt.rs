use opencast_ad_analysis_worker::prompt::{
    build_prompt, gemini_generate_content_url, gemini_request_payload, segment_framing_chars,
    GeminiGenerationOptions, GEMINI_MAX_OUTPUT_TOKENS, PROMPT_OVERHEAD_CHAR_ALLOWANCE,
};
use opencast_ad_analysis_worker::types::{
    resolve_gemini_model, AdAnalysisRequest, TranscriptMetadata, TranscriptSegment,
    GEMINI_MODEL_ALLOWLIST, GEMINI_MODEL_DEFAULT, MAX_LANGUAGE_CODE_CHARS, MAX_PODCAST_ID_CHARS,
    MAX_TITLE_CHARS, POLICY_NAME, SCHEMA_VERSION,
};

#[test]
fn prompt_carries_the_promo_ad_breaks_v2_contract() {
    let request = sample_request();

    let prompt = build_prompt(&request);

    assert!(prompt.contains(&format!("Policy: {POLICY_NAME}")));
    assert_eq!(POLICY_NAME, "promo_ad_breaks_v2");
    assert!(prompt.starts_with(
        "You are marking complete skippable ad breaks inside podcast transcript segments"
    ));
    assert!(prompt.contains("An ad break is the full contiguous run of promotional content"));
    assert!(prompt.contains("Mark whole ad breaks, not individual sentences."));
    assert!(prompt.contains("return ONE span from the first promotional segment to the last"));
    assert!(prompt.contains("The transcript comes from a small on-device speech model"));
    assert!(prompt.contains("never start a span on hosts merely joking about sponsors"));
    assert!(prompt.contains("pick the kind covering most of the break; do not split the break"));
    assert!(prompt.contains("Use only submitted segment IDs for boundaries"));
    // The single tested addition to the proven breaks_v2 text.
    assert!(prompt.contains("- If the segments contain no ad breaks, return {\"spans\": []}.\n"));
    // The verbatim evidence addition was dropped after it measurably regressed
    // gemini-3.1-flash-lite during a prompt bisect; it must not resurface.
    assert!(!prompt.contains("copied verbatim"));
    assert!(prompt.contains(
        "- evidence_quote: quote one promotional cue from inside the span, under 12 words.\n"
    ));
    // Old ads_only cue-anchored contract must be gone.
    assert!(!prompt.contains("Every returned span must contain a concrete promo/ad cue"));
    assert!(!prompt.contains("Fortinet"));
    assert!(!prompt.contains("Prefer tight boundaries"));
    assert!(prompt.contains("[10 | 1.250-3.500] Sponsor copy."));
    assert!(prompt.contains("[11 | 3.500-8.000] Back to editorial discussion."));
    assert!(!prompt.contains("start_time"));
}

#[test]
fn gemini_payload_requests_structured_json_with_thinking_headroom() {
    let payload = gemini_request_payload(&sample_request(), GeminiGenerationOptions::default());

    assert_eq!(
        payload["generationConfig"]["temperature"],
        serde_json::json!(0)
    );
    assert_eq!(payload["generationConfig"]["topP"], serde_json::json!(0.95));
    assert_eq!(
        payload["generationConfig"]["maxOutputTokens"],
        serde_json::json!(16384)
    );
    assert_eq!(GEMINI_MAX_OUTPUT_TOKENS, 16_384);
    assert_eq!(
        payload["generationConfig"]["responseMimeType"],
        "application/json"
    );
    assert_eq!(
        payload["generationConfig"]["responseJsonSchema"]["properties"]["spans"]["items"]
            ["properties"]["kind"]["enum"],
        serde_json::json!(["host_read_ad", "inserted_ad", "house_or_network_promo"])
    );
    // Model defaults were what the validation experiments measured — no
    // thinkingConfig may be sent.
    assert!(payload["generationConfig"].get("thinkingConfig").is_none());
}

#[test]
fn gemini_payload_exposes_dormant_output_and_thinking_options() {
    let payload = gemini_request_payload(
        &sample_request(),
        GeminiGenerationOptions {
            max_output_tokens: 32_768,
            thinking_budget: Some(8_192),
        },
    );

    assert_eq!(
        payload["generationConfig"]["maxOutputTokens"],
        serde_json::json!(32768)
    );
    assert_eq!(
        payload["generationConfig"]["thinkingConfig"]["thinkingBudget"],
        serde_json::json!(8192)
    );
}

#[test]
fn gemini_url_uses_the_resolved_model() {
    assert_eq!(
        gemini_generate_content_url("gemini-3.5-flash"),
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent"
    );
    assert_eq!(
        gemini_generate_content_url("gemini-3.1-flash-lite"),
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent"
    );
}

#[test]
fn model_env_var_resolves_against_the_allowlist() {
    assert_eq!(GEMINI_MODEL_DEFAULT, "gemini-3.5-flash");
    assert_eq!(
        GEMINI_MODEL_ALLOWLIST,
        ["gemini-3.5-flash", "gemini-3.1-flash-lite"]
    );

    assert_eq!(resolve_gemini_model(None), "gemini-3.5-flash");
    assert_eq!(
        resolve_gemini_model(Some("gemini-3.5-flash")),
        "gemini-3.5-flash"
    );
    assert_eq!(
        resolve_gemini_model(Some("gemini-3.1-flash-lite")),
        "gemini-3.1-flash-lite"
    );
    assert_eq!(
        resolve_gemini_model(Some(" gemini-3.1-flash-lite ")),
        "gemini-3.1-flash-lite"
    );
    // Never 2.5-flash (returns seconds in the segment-ID fields) or anything
    // else off the allowlist.
    assert_eq!(
        resolve_gemini_model(Some("gemini-2.5-flash")),
        "gemini-3.5-flash"
    );
    assert_eq!(resolve_gemini_model(Some("")), "gemini-3.5-flash");
    assert_eq!(resolve_gemini_model(Some("gpt-4o")), "gemini-3.5-flash");
}

#[test]
fn gemini_payload_sends_transcript_segments_without_audio_provenance() {
    let request = sample_request();
    let payload = gemini_request_payload(&request, GeminiGenerationOptions::default());
    let encoded = serde_json::to_string(&payload).expect("payload serializes");

    assert!(encoded.contains("Sponsor copy."));
    assert!(encoded.contains("[10 | 1.250-3.500]"));
    assert!(!encoded.contains("sourceAudioURL"));
    assert!(!encoded.contains("sourceFileSHA256"));
    assert!(!encoded.contains("sourceFileByteCount"));
    assert!(!encoded.contains("source_audio_url"));
    assert!(!encoded.contains("source_file_sha256"));
    assert!(!encoded.contains("source_file_byte_count"));
    assert!(!encoded.contains("audio.mp3"));
    assert!(!encoded.contains("source-sha"));
}

/// Pins `PROMPT_OVERHEAD_CHAR_ALLOWANCE` to the real template: everything
/// `build_prompt` emits beyond per-segment lines — the fixed instruction
/// block plus a deliberately oversized metadata header — must fit inside
/// the allowance `validation.rs` folds into the spend estimate. If template
/// growth breaks this, raise the allowance with it instead of silently
/// under-counting spend.
#[test]
fn prompt_overhead_fits_inside_the_spend_allowance() {
    let mut request = sample_request();
    request.segments.clear();
    request.transcript.segment_count = 0;
    // The worst header validation admits (AA-2 caps): a max-length episode
    // title, an ABSENT podcast title so build_prompt falls back to a
    // max-length podcast_id (the direct app path's canonical feed URL), and
    // a max-length language code.
    request.episode_title = Some("E".repeat(MAX_TITLE_CHARS));
    request.podcast_title = None;
    request.podcast_id = "p".repeat(MAX_PODCAST_ID_CHARS);
    request.transcript.language_code = "x".repeat(MAX_LANGUAGE_CODE_CHARS);

    let overhead_chars = build_prompt(&request).chars().count();

    assert!(
        overhead_chars <= PROMPT_OVERHEAD_CHAR_ALLOWANCE,
        "prompt overhead {overhead_chars} chars exceeds the \
         {PROMPT_OVERHEAD_CHAR_ALLOWANCE}-char allowance"
    );
    // The allowance must also stay honest work, not slack that hides a
    // template rewrite: the fixed block alone is the dominant share.
    assert!(
        overhead_chars >= PROMPT_OVERHEAD_CHAR_ALLOWANCE / 2,
        "prompt overhead {overhead_chars} chars is under half the allowance — \
         re-derive PROMPT_OVERHEAD_CHAR_ALLOWANCE against the current template"
    );
}

/// Pins `segment_framing_chars` against `build_prompt`'s actual output so the
/// spend estimate's per-segment framing term (AA-3) stays byte-exact with the
/// template. Renders the prompt with full text, with empty text, and with no
/// segments, and asserts the framing sum reconciles all three.
#[test]
fn per_segment_framing_reconciles_the_rendered_prompt() {
    let request = sample_request();

    let full = build_prompt(&request).chars().count();

    let mut empty_text = request.clone();
    for segment in &mut empty_text.segments {
        segment.text = String::new();
    }
    let header_plus_framing = build_prompt(&empty_text).chars().count();

    let mut headerless = request.clone();
    headerless.segments.clear();
    headerless.transcript.segment_count = 0;
    let header_only = build_prompt(&headerless).chars().count();

    let text_chars: usize = request
        .segments
        .iter()
        .map(|segment| segment.text.chars().count())
        .sum();
    let framing_sum: usize = request.segments.iter().map(segment_framing_chars).sum();

    // full = header + framing + text; empty-text drops only the text.
    assert_eq!(full, header_plus_framing + text_chars);
    // header-only drops the framing; the difference is exactly the framing sum.
    assert_eq!(header_plus_framing, header_only + framing_sum);
}

/// `{:.3}` rounds before printing, so a timing just under a power of ten
/// gains an integer digit (9.9996 renders "10.000"). The width helper must
/// round the same way, not truncate.
#[test]
fn framing_width_survives_round_up_across_a_power_of_ten() {
    for (start, end) in [(9.999_6, 99.999_5), (0.999_9, 9.999_9), (7.25, 999.999_6)] {
        let segment = TranscriptSegment {
            id: 7,
            start,
            end,
            text: String::new(),
        };
        let rendered = format!(
            "[{} | {:.3}-{:.3}] \n",
            segment.id, segment.start, segment.end
        );
        assert_eq!(
            segment_framing_chars(&segment),
            rendered.chars().count(),
            "width mismatch for {start}-{end}: rendered {rendered:?}"
        );
    }
}

fn sample_request() -> AdAnalysisRequest {
    AdAnalysisRequest {
        schema_version: SCHEMA_VERSION,
        async_supported: false,
        request_id: "request-1".to_string(),
        episode_id: "episode-1".to_string(),
        podcast_id: "podcast-1".to_string(),
        episode_title: Some("Episode".to_string()),
        podcast_title: Some("Podcast".to_string()),
        transcript: TranscriptMetadata {
            language_code: "en".to_string(),
            audio_duration: 8.0,
            model_identifier: Some("large-v3".to_string()),
            model_version: Some("v1".to_string()),
            model_tree_sha256: Some("abc".to_string()),
            fingerprint: "fingerprint".to_string(),
            updated_at: "2026-07-01T00:00:00Z".to_string(),
            state: "completed".to_string(),
            segment_count: 2,
        },
        segments: vec![
            TranscriptSegment {
                id: 10,
                start: 1.25,
                end: 3.5,
                text: "Sponsor copy.".to_string(),
            },
            TranscriptSegment {
                id: 11,
                start: 3.5,
                end: 8.0,
                text: "Back to editorial discussion.".to_string(),
            },
        ],
    }
}
