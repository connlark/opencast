use serde_json::json;

use crate::types::{AdAnalysisRequest, TranscriptSegment, POLICY_NAME};

/// Thinking models spend from this budget; 4 096 was the measured truncation
/// trigger in production.
pub const GEMINI_MAX_OUTPUT_TOKENS: u32 = 16_384;

/// Chars the assembled prompt adds on top of raw transcript text from the
/// non-segment side: the fixed instruction block in `build_prompt` plus the
/// policy/episode/podcast/language/duration header. `validation.rs` folds
/// this allowance into the token estimate ahead of the spend caps; the pin
/// test in `tests/prompt.rs` renders the real template with an oversized
/// header and fails the build if template growth pushes past the allowance
/// (which would otherwise silently under-count spend). Per-segment framing
/// chars ("[id | 0.000-0.000] ") are outside this allowance.
pub const PROMPT_OVERHEAD_CHAR_ALLOWANCE: usize = 8_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GeminiGenerationOptions {
    pub max_output_tokens: u32,
    pub thinking_budget: Option<u32>,
}

impl Default for GeminiGenerationOptions {
    fn default() -> Self {
        Self {
            max_output_tokens: GEMINI_MAX_OUTPUT_TOKENS,
            thinking_budget: None,
        }
    }
}

pub const RESPONSE_SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "spans": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind": {
            "type": "string",
            "enum": ["host_read_ad", "inserted_ad", "house_or_network_promo"]
          },
          "label": { "type": "string" },
          "start_segment_id": { "type": "integer" },
          "end_segment_id": { "type": "integer" },
          "confidence": { "type": "number" },
          "evidence_quote": { "type": "string" }
        },
        "required": [
          "kind",
          "label",
          "start_segment_id",
          "end_segment_id",
          "confidence",
          "evidence_quote"
        ]
      }
    }
  },
  "required": ["spans"]
}"#;

// The live-tested `breaks_v2` contract plus exactly one
// addition: the explicit empty-valid final rule. The eval runner at
// Keep this policy text byte-identical to any external evaluation harness.
pub fn build_prompt(request: &AdAnalysisRequest) -> String {
    let mut text = String::new();
    text.push_str(
        "You are marking complete skippable ad breaks inside podcast transcript segments so a podcast app can skip each break in a single jump.\n\n",
    );
    text.push_str("Return only JSON matching the supplied schema.\n\n");
    text.push_str("An ad break is the full contiguous run of promotional content: every sponsor read, dynamically inserted ad, legal or medical disclaimer, coupon code, and CTA between the moment show content stops and the moment show content clearly resumes.\n\n");
    text.push_str("Rules:\n");
    text.push_str("- Mark whole ad breaks, not individual sentences. If two or more ads play back-to-back (for example a sponsor read followed by an inserted ad and a charity promo), return ONE span from the first promotional segment to the last, even when the middle segments never name the sponsor.\n");
    text.push_str("- The interior of an ad often sounds like plain product description, medical side-effect copy, betting odds, or legal disclaimers with no brand name. Those segments belong to the break. Do not end a span until the hosts actually resume conversation about the show topic.\n");
    text.push_str("- The transcript comes from a small on-device speech model: brand names are frequently misspelled (e.g. \"Fenduel\"/\"Fan Dual\" for FanDuel) and words are garbled. Judge by structure and intent, not exact spelling.\n");
    text.push_str("- Include lead-in and lead-out transition lines like \"a word from our sponsors\" or \"welcome back\" only when they are part of the promotional read itself; never start a span on hosts merely joking about sponsors or advertising.\n");
    text.push_str("- Exclude editorial discussion of companies and products, casual brand mentions, and hosts riffing or joking about fictional or real sponsors. A joke about \"our offshore betting sponsor\" without an actual read is show content.\n");
    text.push_str("- kind: use inserted_ad for produced/inserted spots, host_read_ad for host-voiced sponsor reads, house_or_network_promo for network/show promos. If a break mixes kinds, pick the kind covering most of the break; do not split the break.\n");
    text.push_str("- confidence reflects how sure you are that the whole span is skippable without losing show content.\n");
    text.push_str(
        "- evidence_quote: quote one promotional cue from inside the span, under 12 words.\n",
    );
    text.push_str("- Use only submitted segment IDs for boundaries; never invent timestamps.\n");
    text.push_str("- If the segments contain no ad breaks, return {\"spans\": []}.\n\n");
    text.push_str(&format!("Policy: {POLICY_NAME}\n"));
    text.push_str(&format!(
        "Episode: {}\nPodcast: {}\nLanguage: {}\nAudio duration: {:.3}s\n\n",
        request
            .episode_title
            .as_deref()
            .unwrap_or(&request.episode_id),
        request
            .podcast_title
            .as_deref()
            .unwrap_or(&request.podcast_id),
        request.transcript.language_code,
        request.transcript.audio_duration
    ));
    text.push_str("Segments:\n");
    for segment in &request.segments {
        text.push_str(&format!(
            "[{} | {:.3}-{:.3}] {}\n",
            segment.id, segment.start, segment.end, segment.text
        ));
    }
    text
}

/// The non-text chars `build_prompt` emits for one segment line:
/// `[{id} | {start:.3}-{end:.3}] ` plus the trailing `\n`, excluding the
/// segment text. Rendered with the same format string `build_prompt` uses
/// (the pin tests assert the two never drift), so the spend estimate is
/// byte-exact by construction — arithmetic width prediction was retired
/// after `{:.3}`'s rounding (9.9996 → "10.000") defeated it at power-of-ten
/// boundaries. One short allocation per segment,
/// still without rendering the whole prompt (AA-3).
pub fn segment_framing_chars(segment: &TranscriptSegment) -> usize {
    format!(
        "[{} | {:.3}-{:.3}] \n",
        segment.id, segment.start, segment.end
    )
    .chars()
    .count()
}

pub fn gemini_request_payload(
    request: &AdAnalysisRequest,
    options: GeminiGenerationOptions,
) -> serde_json::Value {
    let schema: serde_json::Value =
        serde_json::from_str(RESPONSE_SCHEMA).expect("response schema is valid JSON");
    let mut generation_config = json!({
        "temperature": 0,
        "topP": 0.95,
        "maxOutputTokens": options.max_output_tokens,
        "responseMimeType": "application/json",
        "responseJsonSchema": schema
    });
    if let Some(thinking_budget) = options.thinking_budget {
        generation_config["thinkingConfig"] = json!({
            "thinkingBudget": thinking_budget
        });
    }

    json!({
        "contents": [
            {
                "role": "user",
                "parts": [
                    { "text": build_prompt(request) }
                ]
            }
        ],
        "generationConfig": generation_config
    })
}

pub fn gemini_generate_content_url(model: &str) -> String {
    format!("https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent")
}
