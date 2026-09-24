use opencast_ad_analysis_worker::{
    promo_v3::{self, Output, Span},
    types::{AdAnalysisRequest, TranscriptMetadata, TranscriptSegment},
};

fn request() -> AdAnalysisRequest {
    AdAnalysisRequest {
        schema_version: 1,
        async_supported: false,
        retry_failed: false,
        job_handle_version: None,
        request_id: "test".into(),
        episode_id: "episode".into(),
        podcast_id: "show".into(),
        episode_title: None,
        podcast_title: None,
        transcript: TranscriptMetadata {
            language_code: "en".into(),
            audio_duration: 1500.0,
            declared_duration: None,
            model_identifier: None,
            model_version: None,
            model_tree_sha256: None,
            fingerprint: "test".into(),
            updated_at: "test".into(),
            state: "completed".into(),
            segment_count: 6,
        },
        segments: vec![
            (
                106,
                0.0,
                600.0,
                "We discussed the history of paper advertisements.",
            ),
            (
                306,
                600.0,
                606.8,
                "Listen to Harbor Stories wherever you get podcasts.",
            ),
            (
                398,
                606.8,
                620.0,
                "Meet the people who make the harbor their home. Subscribe today.",
            ),
            (
                399,
                620.0,
                1200.0,
                "Now returning to the history of boat construction.",
            ),
            (
                646,
                1200.0,
                1206.8,
                "Listen to Harbor Stories wherever you get podcasts.",
            ),
            (
                739,
                1206.8,
                1500.0,
                "That concludes our boatbuilding lesson, goodbye.",
            ),
        ]
        .into_iter()
        .map(|(id, start, end, text)| TranscriptSegment {
            id,
            start,
            end,
            text: text.into(),
        })
        .collect(),
    }
}

fn short_span(id: i64) -> Span {
    Span {
        kind: "house_or_network_promo".into(),
        label: "Harbor Stories trailer".into(),
        start_segment_id: id,
        end_segment_id: id,
        confidence: 0.95,
        start_quote: "Listen to Harbor Stories".into(),
        end_quote: "wherever you get podcasts".into(),
        evidence_quote: "Listen to Harbor Stories".into(),
    }
}

#[test]
fn short_real_promos_and_repeated_occurrences_survive() {
    let result = promo_v3::validate(
        &request(),
        Output {
            spans: vec![short_span(306), short_span(646)],
        },
    );
    assert!(result.is_complete(), "{:?}", result.issues);
    assert_eq!(result.spans.len(), 2);
    assert!((result.spans[0].end_time - result.spans[0].start_time - 6.8).abs() < 1e-6);
}

#[test]
fn receipts_survive_short_mixed_boundaries_and_wire_round_trip() {
    let mut input = request();
    input.segments[1].text =
        "Listen to Harbor Stories wherever you get podcasts. President Trump spoke.".into();
    let result = promo_v3::validate(
        &input,
        Output {
            spans: vec![short_span(306)],
        },
    );
    assert!(result.is_complete());
    let span = &result.spans[0];
    assert_eq!(span.end_time, 606.8);
    assert_eq!(
        span.end_boundary.as_ref().unwrap().quote,
        "wherever you get podcasts"
    );
    assert_eq!(span.end_boundary.as_ref().unwrap().segment_id, 306);
    let json = serde_json::to_value(span).unwrap();
    assert_eq!(json["end_boundary"]["segment_id"], 306);
    let decoded: opencast_ad_analysis_worker::types::ValidatedAdSpan =
        serde_json::from_value(json).unwrap();
    assert_eq!(&decoded, span);
}

#[test]
fn legacy_span_without_anchors_remains_decodable() {
    let result = promo_v3::validate(
        &request(),
        Output {
            spans: vec![short_span(306)],
        },
    );
    let mut json = serde_json::to_value(&result.spans[0]).unwrap();
    json.as_object_mut().unwrap().remove("start_boundary");
    json.as_object_mut().unwrap().remove("end_boundary");
    let decoded: opencast_ad_analysis_worker::types::ValidatedAdSpan =
        serde_json::from_value(json).unwrap();
    assert!(decoded.start_boundary.is_none());
    assert!(decoded.end_boundary.is_none());
}

#[test]
fn wrong_but_existing_start_id_cannot_borrow_an_interior_receipt() {
    let mut span = short_span(306);
    span.start_segment_id = 106;
    let result = promo_v3::validate(&request(), Output { spans: vec![span] });
    assert!(!result.is_complete());
    assert!(result.spans.is_empty());
    assert_eq!(result.issues, vec!["v3_boundary_receipt_mismatch:106-306"]);
}

#[test]
fn wrong_end_id_cannot_slide_whole_break_to_matching_cue() {
    let mut span = short_span(306);
    span.end_segment_id = 399;
    let result = promo_v3::validate(&request(), Output { spans: vec![span] });
    assert!(!result.is_complete());
    assert!(result.spans.is_empty());
}

#[test]
fn one_invalid_candidate_marks_the_whole_result_incomplete() {
    let mut invalid = short_span(646);
    invalid.start_segment_id = 777;
    let result = promo_v3::validate(
        &request(),
        Output {
            spans: vec![short_span(306), invalid],
        },
    );
    assert_eq!(result.spans.len(), 1);
    assert!(!result.is_complete());
}

#[test]
fn input_has_ids_and_text_but_no_competing_timestamps() {
    let input: serde_json::Value = serde_json::from_str(&promo_v3::input(&request())).unwrap();
    assert_eq!(input["segments"][0]["id"], 106);
    assert!(input["segments"][0].get("start").is_none());
    assert!(input.get("audio_duration").is_none());
    let payload = promo_v3::payload(&request(), Some("low"));
    assert!(payload["systemInstruction"]["parts"][0]["text"]
        .as_str()
        .unwrap()
        .contains("untrusted"));
}

#[test]
fn empty_output_remains_valid_without_inventing_coverage_certainty() {
    assert!(promo_v3::validate(&request(), Output { spans: vec![] }).is_complete());
}

#[test]
fn long_mixed_boundary_segments_shrink_inward_without_inventing_word_times() {
    let mut request = request();
    request.segments[1].text =
        "Back to boats. Listen to Harbor Stories wherever you get podcasts.".into();
    request.segments[1].start = 590.0;
    let mut span = short_span(306);
    span.end_segment_id = 398;
    span.end_quote = "Subscribe today".into();
    let result = promo_v3::validate(&request, Output { spans: vec![span] });
    assert!(result.is_complete(), "{:?}", result.issues);
    assert_eq!(result.spans[0].start_segment_id, 398);
    assert_eq!(
        result.spans[0].start_boundary.as_ref().unwrap().segment_id,
        306
    );
    assert_eq!(result.notices, ["v3_boundary_trimmed:306-398->398-398"]);
    let single = promo_v3::validate(
        &request,
        Output {
            spans: vec![short_span(306)],
        },
    );
    assert!(!single.is_complete());
}

#[test]
fn short_mixed_boundaries_keep_the_entire_ad_opening_and_signoff() {
    let mut request = request();
    request.segments[1].text =
        "Back to boats. Listen to Harbor Stories wherever you get podcasts. Our next boat.".into();
    let result = promo_v3::validate(
        &request,
        Output {
            spans: vec![short_span(306)],
        },
    );
    assert!(result.is_complete(), "{:?}", result.issues);
    assert_eq!(result.spans[0].start_time, 600.0);
    assert_eq!(result.spans[0].end_time, 606.8);
    assert_eq!(result.notices, ["v3_short_mixed_boundary_included:306-306"]);
}

#[test]
fn mixed_boundary_allowance_is_bounded_per_edge_not_per_break() {
    let mut request = request();
    request.segments[1].text = "Boats. Listen to Harbor Stories wherever you get podcasts.".into();
    request.segments[1].end = 610.0;
    request.segments[2].start = 610.0;
    request.segments[2].text = "Subscribe today. Now let us talk about boats.".into();
    let mut span = short_span(306);
    span.end_segment_id = 398;
    span.end_quote = "Subscribe today".into();
    let result = promo_v3::validate(
        &request,
        Output {
            spans: vec![span.clone()],
        },
    );
    assert!(result.is_complete());
    assert_eq!(result.spans[0].start_segment_id, 306);
    assert_eq!(result.spans[0].end_segment_id, 398);
    // Crossing ten seconds cannot silently expand the allowance.
    request.segments[2].end = 620.001;
    let result = promo_v3::validate(&request, Output { spans: vec![span] });
    assert!(result.is_complete());
    assert_eq!(result.spans[0].end_segment_id, 306);
}

#[test]
fn full_ad_window_is_allowed_but_full_ad_request_is_an_alarm() {
    let mut request = request();
    request.segments = vec![request.segments[1].clone()];
    request.transcript.segment_count = 1;
    let output = Output {
        spans: vec![short_span(306)],
    };
    assert!(promo_v3::validate_window(&request, output.clone()).is_complete());
    assert!(!promo_v3::validate(&request, output).is_complete());
}

#[test]
fn strict_finish_reason_and_thought_usage() {
    let response = serde_json::json!({"candidates":[{"finishReason":"STOP","content":{"parts":[
        {"thought":true,"text":"not an answer"}, {"text":"{\"spans\":[]}"}
    ]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"thoughtsTokenCount":7,"totalTokenCount":15}});
    let parsed = promo_v3::parse_response(&response.to_string());
    assert!(parsed.output.is_some());
    assert_eq!(parsed.usage.unwrap().total_token_count, 22);
    let mut truncated = response;
    truncated["candidates"][0]["finishReason"] = serde_json::json!("MAX_TOKENS");
    assert_eq!(
        promo_v3::parse_response(&truncated.to_string()).issue,
        Some("v3_incomplete_generation")
    );
}

#[test]
fn repair_cannot_erase_rejected_or_previously_valid_breaks() {
    let request = request();
    let mut bad = short_span(306);
    bad.start_segment_id = 106;
    let before = Output {
        spans: vec![bad, short_span(646)],
    };
    let old = promo_v3::validate_window(&request, before.clone());
    let empty = promo_v3::validate_window(&request, Output { spans: vec![] });
    assert!(!promo_v3::preserves_verified_breaks(&old, &empty));
    let partial = promo_v3::validate_window(
        &request,
        Output {
            spans: vec![short_span(646)],
        },
    );
    assert!(promo_v3::preserves_verified_breaks(&old, &partial));
    assert!(!promo_v3::preserves_candidate_evidence(
        &request,
        &before,
        &Output {
            spans: vec![short_span(646)]
        }
    ));
    let fixed = promo_v3::validate_window(
        &request,
        Output {
            spans: vec![short_span(306), short_span(646)],
        },
    );
    assert!(promo_v3::preserves_verified_breaks(&old, &fixed));
    assert!(promo_v3::preserves_candidate_evidence(
        &request,
        &before,
        &Output {
            spans: vec![short_span(306), short_span(646)]
        }
    ));
}

#[test]
fn repair_can_correct_a_hallucinated_cue_without_erasing_its_occurrence() {
    let request = request();
    let mut bad = short_span(306);
    bad.evidence_quote = "Subscribe to a sentence that does not exist".into();
    let before = Output { spans: vec![bad] };
    assert!(!promo_v3::validate_window(&request, before.clone()).is_complete());
    let fixed = Output {
        spans: vec![short_span(306)],
    };
    assert!(promo_v3::validate_window(&request, fixed.clone()).is_complete());
    assert!(promo_v3::preserves_candidate_evidence(
        &request, &before, &fixed
    ));
    // The same trailer elsewhere cannot stand in for this occurrence.
    assert!(!promo_v3::preserves_candidate_evidence(
        &request,
        &before,
        &Output {
            spans: vec![short_span(646)]
        }
    ));
    let mut unlocatable = before;
    unlocatable.spans[0].start_quote = "invented opening".into();
    unlocatable.spans[0].end_quote = "invented ending".into();
    assert!(!promo_v3::preserves_candidate_evidence(
        &request,
        &unlocatable,
        &fixed
    ));
}

#[test]
fn unknown_boundary_cannot_borrow_another_repeated_occurrence_during_repair() {
    let request = request();
    let mut unknown = short_span(646);
    unknown.start_segment_id = 777;
    let before = Output {
        spans: vec![short_span(306), unknown],
    };
    assert!(!promo_v3::preserves_candidate_evidence(
        &request,
        &before,
        &Output {
            spans: vec![short_span(306)]
        }
    ));
    assert!(promo_v3::preserves_candidate_evidence(
        &request,
        &before,
        &Output {
            spans: vec![short_span(306), short_span(646)]
        }
    ));
}

#[test]
fn duplicate_confidence_tiers_preserve_auto_skip_without_double_counting_time() {
    let mut request = request();
    request.transcript.audio_duration = 2400.0;
    for (segment, (start, end)) in request.segments.iter_mut().zip([
        (0.0, 600.0),
        (600.0, 1000.0),
        (1000.0, 1010.0),
        (1010.0, 1800.0),
        (1800.0, 1806.8),
        (1806.8, 2400.0),
    ]) {
        segment.start = start;
        segment.end = end;
    }
    let mut low = short_span(306);
    low.confidence = 0.7;
    let result = promo_v3::validate(
        &request,
        Output {
            spans: vec![low, short_span(306)],
        },
    );
    assert!(result.is_complete(), "{:?}", result.issues);
    assert!(result.spans.iter().any(|s| s.confidence >= 0.8));
}

#[test]
fn interleaved_confidence_tiers_cannot_bypass_the_merged_break_limit() {
    let mut request = request();
    request.transcript.audio_duration = 3000.0;
    request.segments = (0..40)
        .map(|id| TranscriptSegment {
            id,
            start: id as f64 * 20.0,
            end: (id + 1) as f64 * 20.0,
            text: "Listen to Harbor Stories wherever you get podcasts.".into(),
        })
        .collect();
    request.transcript.segment_count = request.segments.len();
    let mut first = short_span(0);
    first.end_segment_id = 19;
    let mut second = short_span(15);
    second.end_segment_id = 30;
    let mut low = short_span(10);
    low.confidence = 0.7;
    let result = promo_v3::validate(
        &request,
        Output {
            spans: vec![first, low, second],
        },
    );
    assert!(result
        .issues
        .iter()
        .any(|i| i == "v3_merged_break_duration"));
}

#[test]
fn dynamically_inserted_pods_fit_the_declared_runtime_excess_budget() {
    // 180 x 20 s = 3,600 s served file carrying three 500 s pods (1,500 s).
    let mut request = request();
    request.transcript.audio_duration = 3600.0;
    request.segments = (0..180)
        .map(|id| TranscriptSegment {
            id,
            start: id as f64 * 20.0,
            end: (id + 1) as f64 * 20.0,
            text: "Listen to Harbor Stories wherever you get podcasts.".into(),
        })
        .collect();
    request.transcript.segment_count = request.segments.len();
    let pods = || {
        [(0, 24), (60, 84), (120, 144)]
            .into_iter()
            .map(|(start, end)| {
                let mut span = short_span(start);
                span.end_segment_id = end;
                span
            })
            .collect::<Vec<_>>()
    };
    // Audio-only budget: max(0.40 x 3,600, 600) = 1,440 s < 1,500 s.
    let audio_only = promo_v3::validate(&request, Output { spans: pods() });
    assert!(
        audio_only
            .issues
            .iter()
            .any(|i| i == "v3_ad_budget_exceeded"),
        "{:?}",
        audio_only.issues
    );
    // The feed declared 2,400 s, so 1,200 s of the file is inserted
    // advertising: budget max(0.40 x 2,400, 600) + 1,200 = 2,160 s.
    request.transcript.declared_duration = Some(2400.0);
    let declared = promo_v3::validate(&request, Output { spans: pods() });
    assert!(declared.is_complete(), "{:?}", declared.issues);
    assert_eq!(declared.spans.len(), 3);
    // An implausibly short declared runtime earns nothing.
    request.transcript.declared_duration = Some(900.0);
    let implausible = promo_v3::validate(&request, Output { spans: pods() });
    assert!(implausible
        .issues
        .iter()
        .any(|i| i == "v3_ad_budget_exceeded"));
}

#[test]
fn serving_bundle_cache_and_quota_are_policy_specific() {
    use opencast_ad_analysis_worker::policy::{
        AnalysisPolicy, V3_INITIAL_ATTEMPTS, V3_MAX_BACKOFF_SECONDS, V3_MODEL, V3_REPAIR_ATTEMPTS,
    };
    assert_eq!(AnalysisPolicy::resolve(None), AnalysisPolicy::V2);
    assert_eq!(AnalysisPolicy::resolve(Some("typo")), AnalysisPolicy::V2);
    assert_eq!(
        AnalysisPolicy::resolve(Some(promo_v3::POLICY)),
        AnalysisPolicy::V3
    );
    assert_eq!(
        AnalysisPolicy::V3.model(Some("gemini-3.1-flash-lite")),
        V3_MODEL
    );
    assert_ne!(
        AnalysisPolicy::V2.job_object_name("id"),
        AnalysisPolicy::V3.job_object_name("id")
    );
    assert_eq!(AnalysisPolicy::V2.admission_tokens(&request(), 42), 42);
    assert!(AnalysisPolicy::V3.admission_tokens(&request(), 42) > 4 * 42);
    use opencast_ad_analysis_worker::{job, retry, types, v3_windowing};
    let count = v3_windowing::window_count(types::MAX_SEGMENTS);
    assert_eq!(count, 9);
    let waves = count.div_ceil(v3_windowing::CONCURRENT_WINDOWS);
    let deadline = waves as u64
        * ((V3_INITIAL_ATTEMPTS + V3_REPAIR_ATTEMPTS) as u64 * retry::GEMINI_CALL_TIMEOUT_SECONDS
            + V3_MAX_BACKOFF_SECONDS);
    assert_eq!(deadline, 570);
    assert_eq!(deadline + 30, job::JOB_RUNNING_DEADLINE_SECONDS as u64);
}

#[test]
fn local_windows_cover_every_segment_and_have_exact_overlap() {
    use opencast_ad_analysis_worker::v3_windowing;
    let mut request = request();
    request.segments = (0..6000)
        .map(|i| TranscriptSegment {
            id: i * 3,
            start: i as f64,
            end: i as f64 + 0.9,
            text: "Program content.".into(),
        })
        .collect();
    request.transcript.segment_count = 6000;
    let windows = v3_windowing::analysis_windows(&request);
    assert_eq!(windows.len(), 9);
    assert_eq!(windows[0].segments.len(), 800);
    assert_eq!(windows[1].segments[0].id, 680 * 3);
    assert_eq!(
        windows.last().unwrap().segments.last().unwrap().id,
        5999 * 3
    );
    for pair in windows.windows(2) {
        assert_eq!(
            pair[0].segments[pair[0].segments.len() - 120..],
            pair[1].segments[..120]
        );
    }
}

#[test]
fn contractions_do_not_turn_a_valid_cue_into_an_incomplete_analysis() {
    let mut request = request();
    request.segments[1].text = "I hope you'll tune in every Sunday for this week in tech.".into();
    let mut span = short_span(306);
    span.start_quote = "I hope you'll tune in every Sunday".into();
    span.end_quote = "for this week in tech".into();
    span.evidence_quote = request.segments[1].text.clone();
    assert!(promo_v3::validate(&request, Output { spans: vec![span] }).is_complete());
}

#[test]
fn uncertain_neighbor_does_not_suppress_a_verified_short_ad() {
    let request = request();
    let mut neighbor = short_span(398);
    neighbor.start_quote = "Meet the people who make the harbor".into();
    neighbor.end_quote = "Subscribe today".into();
    neighbor.evidence_quote = "Subscribe today".into();
    neighbor.confidence = 0.7;
    let result = promo_v3::validate(
        &request,
        Output {
            spans: vec![short_span(306), neighbor],
        },
    );
    assert!(result.is_complete());
    assert_eq!(result.spans.len(), 2);
    assert_eq!(result.spans[0].confidence, 0.95);
}

#[test]
fn correction_includes_actual_failed_boundary_context_as_untrusted_data() {
    let request = request();
    let mut span = short_span(306);
    span.start_segment_id = 106;
    let original = promo_v3::payload(&request, Some("medium"));
    let repaired = promo_v3::repair_payload(
        original.clone(),
        &serde_json::to_value(Output { spans: vec![span] }).unwrap(),
        &["v3_boundary_receipt_mismatch:106-306".into()],
    )
    .unwrap();
    assert_eq!(repaired["systemInstruction"], original["systemInstruction"]);
    let text = repaired["contents"][2]["parts"][0]["text"]
        .as_str()
        .unwrap();
    assert!(text.contains("We discussed the history of paper advertisements."));
    assert!(text.contains("Listen to Harbor Stories wherever you get podcasts."));
    assert!(text.contains("untrusted source data"));
    assert!(text.len() <= promo_v3::MAX_REPAIR_FEEDBACK_BYTES);
}

#[test]
fn ambiguous_short_receipt_requires_unique_extension_at_the_real_edge() {
    let mut input = request();
    input.segments[1].text =
        "Listen now to Harbor Stories. Listen now wherever you get podcasts.".into();
    let mut span = short_span(306);
    span.start_quote = "Listen now".into();
    span.evidence_quote = "Harbor Stories".into();
    assert!(!promo_v3::validate(
        &input,
        Output {
            spans: vec![span.clone()]
        }
    )
    .is_complete());
    span.start_quote = "Listen now to Harbor Stories".into();
    assert!(promo_v3::validate(&input, Output { spans: vec![span] }).is_complete());
    assert!(promo_v3::INSTRUCTIONS.contains("exactly ONCE"));
}

#[test]
fn corrective_feedback_is_bounded_in_release_with_unicode_and_escaping() {
    let mut input = request();
    input.segments[0].id = i64::MIN;
    input.segments[0].text = "漢字\\\"\n".repeat(500);
    let mut span = short_span(306);
    span.start_segment_id = i64::MIN;
    let previous = serde_json::to_value(Output { spans: vec![span] }).unwrap();
    let issues = vec![format!("v3_boundary_receipt_mismatch:{}-306", i64::MIN); 128];
    let payload =
        promo_v3::repair_payload(promo_v3::payload(&input, None), &previous, &issues).unwrap();
    let text = payload["contents"][2]["parts"][0]["text"].as_str().unwrap();
    assert!(text.len() <= promo_v3::MAX_REPAIR_FEEDBACK_BYTES);
    assert!(text.contains("exactly once"));
    assert!(text.contains("v3_boundary_receipt_mismatch"));
    assert!(serde_json::from_str::<serde_json::Value>(&payload.to_string()).is_ok());
    assert!(promo_v3::repair_payload(
        promo_v3::payload(&input, None),
        &previous,
        &vec!["issue".into(); 129]
    )
    .is_err());
    assert!(promo_v3::repair_payload(
        promo_v3::payload(&input, None),
        &serde_json::json!({"data":"語".repeat(100_000)}),
        &issues
    )
    .is_err());
    assert!(promo_v3::repair_payload(
        promo_v3::payload(&input, None),
        &previous,
        &vec!["x".repeat(256); 128]
    )
    .is_err());
}

#[test]
fn source_size_and_finite_execution_allowance_have_different_meanings() {
    use opencast_ad_analysis_worker::{
        accounting, policy::AnalysisPolicy, validation::validate_request,
    };
    let mut input = request();
    input.transcript.fingerprint = "maximum-request".into();
    input.segments = (0..6000)
        .map(|id| TranscriptSegment {
            id,
            start: id as f64,
            end: id as f64 + 1.0,
            text: "a".repeat(40),
        })
        .collect();
    input.transcript.segment_count = 6000;
    input.transcript.audio_duration = 6000.0;
    let admitted = validate_request(input.clone()).unwrap();
    let allowance =
        AnalysisPolicy::V3.admission_tokens(&input, admitted.estimate.estimated_input_tokens);
    assert!(admitted.estimate.estimated_input_tokens <= 120_000);
    assert!(allowance > 120_000);
    assert!(allowance <= accounting::MAX_EXECUTION_INPUT_TOKENS);
}
