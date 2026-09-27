use opencast_transcript_analysis_worker::gemini::GeminiParseError;
use opencast_transcript_analysis_worker::types::{
    AnalysisRunStats, RejectedAttempts, RejectionClass,
};

#[test]
fn rejection_classes_cover_the_validation_rule_table() {
    assert_eq!(
        RejectionClass::for_rule("id_discipline"),
        RejectionClass::IdDiscipline
    );
    for rule in [
        "chapters_shape",
        "chapter_count_cap",
        "chapter_order",
        "chapter_overlap",
        "chapter_title",
        "chapter_confidence",
    ] {
        assert_eq!(
            RejectionClass::for_rule(rule),
            RejectionClass::Chapters,
            "{rule}"
        );
    }
    for rule in [
        "summary_text",
        "summary_length",
        "one_line_text",
        "one_line_length",
    ] {
        assert_eq!(
            RejectionClass::for_rule(rule),
            RejectionClass::Summary,
            "{rule}"
        );
    }
    for rule in ["claims_count", "claim_text"] {
        assert_eq!(
            RejectionClass::for_rule(rule),
            RejectionClass::Claims,
            "{rule}"
        );
    }
    for rule in ["no_urls", "some_future_rule", ""] {
        assert_eq!(
            RejectionClass::for_rule(rule),
            RejectionClass::Other,
            "{rule}"
        );
    }
}

/// One class per rejected attempt, by precedence: seconds in an id field
/// also breaks ordering and overlap, and the id-discipline class is the
/// diagnostic one.
#[test]
fn validation_rejections_record_one_class_by_precedence() {
    let mut rejected = RejectedAttempts::default();
    rejected.record_validation(&["chapter_overlap", "chapter_order", "id_discipline"]);
    rejected.record_validation(&["summary_length", "claim_text"]);
    rejected.record_validation(&["claims_count", "no_urls"]);
    rejected.record_validation(&["no_urls"]);
    rejected.record_validation(&["chapter_title"]);
    rejected.record_validation(&[]);
    assert_eq!(
        rejected,
        RejectedAttempts {
            total: 6,
            id_discipline: 1,
            chapters: 1,
            summary: 1,
            claims: 1,
            parse: 0,
            truncated: 0,
            other: 2,
        }
    );
}

#[test]
fn parse_rejections_split_truncation_from_every_other_parse_failure() {
    let mut rejected = RejectedAttempts::default();
    rejected.record_parse(&GeminiParseError::MaxTokensTruncated);
    rejected.record_parse(&GeminiParseError::MalformedModelJson);
    rejected.record_parse(&GeminiParseError::MalformedResponse);
    rejected.record_parse(&GeminiParseError::MissingCandidateText);
    rejected.record_parse(&GeminiParseError::NonStopFinishReason);
    assert_eq!(rejected.total, 5);
    assert_eq!(rejected.truncated, 1);
    assert_eq!(rejected.parse, 4);
}

/// The classes partition the total after every recording.
#[test]
fn rejected_classes_always_sum_to_the_total() {
    type Step = Box<dyn Fn(&mut RejectedAttempts)>;
    let mut rejected = RejectedAttempts::default();
    let steps: Vec<Step> = vec![
        Box::new(|r| r.record_validation(&["id_discipline", "chapter_order"])),
        Box::new(|r| r.record_parse(&GeminiParseError::MaxTokensTruncated)),
        Box::new(|r| r.record_validation(&["summary_text"])),
        Box::new(|r| r.record_parse(&GeminiParseError::MalformedModelJson)),
        Box::new(|r| r.record_validation(&["claim_text", "no_urls"])),
        Box::new(|r| r.record_validation(&["mystery"])),
        Box::new(|r| r.record_validation(&["chapter_confidence"])),
    ];
    for (index, step) in steps.iter().enumerate() {
        step(&mut rejected);
        let classes: u32 = rejected.class_counts().iter().sum();
        assert_eq!(rejected.total, classes, "after step {index}");
        assert_eq!(rejected.total, u32::try_from(index + 1).unwrap());
    }
}

#[test]
fn run_stats_default_to_a_clean_ladder() {
    let stats = AnalysisRunStats::default();
    assert_eq!(stats.attempts, 0);
    assert_eq!(stats.gemini_call_timeouts, 0);
    assert_eq!(stats.transport_retries, 0);
    assert!(!stats.budget_exhausted);
    assert_eq!(stats.rejected, RejectedAttempts::default());
}
