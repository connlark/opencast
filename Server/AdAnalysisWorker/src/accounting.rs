//! One daily coordination atom checks caller and global limits together. A job
//! owns one request admission; each paid attempt owns a separate input estimate.
//! Receipts are telemetry, never output/thinking tokens subtracted from input.
use serde::{Deserialize, Serialize};

use crate::{types::GeminiUsage, usage::UsageLimitProfile, validation::DailyUsage};

pub const MAX_ATTEMPTS: usize = 27;
pub const MAX_EXECUTION_INPUT_TOKENS: u64 = 1_500_000;
pub const MAX_DAILY_RECORDS: usize = 10_000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum Operation {
    Admit {
        execution_tokens: u64,
        expires_at: u64,
    },
    Reserve {
        attempt: u8,
        input_tokens: u64,
    },
    Dispatch {
        attempt: u8,
    },
    Receipt {
        attempt: u8,
        usage: GeminiUsage,
    },
    Finish,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Request {
    pub run_id: String,
    pub subject: String,
    pub profile: UsageLimitProfile,
    pub day: u64,
    pub legacy_caller: DailyUsage,
    pub operation: Operation,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AttemptState {
    Reserved,
    Dispatched,
    Reported,
    Released,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Attempt {
    pub id: u8,
    pub input_tokens: u64,
    pub state: AttemptState,
    pub usage: Option<GeminiUsage>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Record {
    pub subject: String,
    pub profile: UsageLimitProfile,
    pub day: u64,
    pub expires_at: u64,
    pub execution_tokens: u64,
    pub finished: bool,
    pub attempts: Vec<Attempt>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct Summary {
    pub request_count: u64,
    pub reserved_input_tokens: u64,
    pub dispatched_input_tokens: u64,
    pub released_input_tokens: u64,
    pub dispatched_attempts: u64,
    pub unknown_attempts: u64,
    pub reported_usage: Option<GeminiUsage>,
}

impl Record {
    pub fn summary(&self) -> Summary {
        let mut summary = Summary::default();
        for attempt in &self.attempts {
            match attempt.state {
                AttemptState::Reserved => summary.reserved_input_tokens += attempt.input_tokens,
                AttemptState::Released => summary.released_input_tokens += attempt.input_tokens,
                AttemptState::Dispatched | AttemptState::Reported => {
                    summary.dispatched_input_tokens += attempt.input_tokens;
                    summary.dispatched_attempts += 1;
                    summary.unknown_attempts += u64::from(attempt.usage.is_none());
                    if let Some(usage) = &attempt.usage {
                        let total = summary.reported_usage.get_or_insert(GeminiUsage {
                            prompt_token_count: 0,
                            candidates_token_count: 0,
                            thoughts_token_count: 0,
                            total_token_count: 0,
                        });
                        total.prompt_token_count = total
                            .prompt_token_count
                            .saturating_add(usage.prompt_token_count);
                        total.candidates_token_count = total
                            .candidates_token_count
                            .saturating_add(usage.candidates_token_count);
                        total.thoughts_token_count = total
                            .thoughts_token_count
                            .saturating_add(usage.thoughts_token_count);
                        total.total_token_count = total
                            .total_token_count
                            .saturating_add(usage.total_token_count);
                    }
                }
            }
        }
        summary.request_count = u64::from(!self.finished || summary.dispatched_attempts > 0);
        summary
    }

    pub fn charged(&self) -> DailyUsage {
        let summary = self.summary();
        DailyUsage {
            request_count: summary.request_count,
            estimated_input_tokens: summary.reserved_input_tokens + summary.dispatched_input_tokens,
        }
    }

    pub fn finish(&mut self) {
        self.finished = true;
        for attempt in &mut self.attempts {
            if attempt.state == AttemptState::Reserved {
                attempt.state = AttemptState::Released;
            }
        }
    }
}

/// Pure transition; the DO persists the resulting record in ONE SQL statement.
/// Totals include the current record, so retries cannot mint extra allowance.
pub fn apply(
    record: Option<&Record>,
    request: &Request,
    caller: DailyUsage,
    global: DailyUsage,
    now: u64,
) -> Result<Record, &'static str> {
    if request.subject.is_empty()
        || request.subject.len() > 256
        || !(8..=128).contains(&request.run_id.len())
        || request.profile == UsageLimitProfile::Global
    {
        return Err("invalid_accounting_request");
    }
    if let Some(record) = record {
        if record.subject != request.subject
            || record.day != request.day
            || record.profile != request.profile
        {
            return Err("accounting_identity_mismatch");
        }
    }
    let check = |requests: u64, tokens: u64| -> Result<(), &'static str> {
        for (usage, limits) in [
            (&caller, request.profile.limits()),
            (&global, UsageLimitProfile::Global.limits()),
        ] {
            if usage.request_count.saturating_add(requests) > limits.request_cap {
                return Err(limits.request_error.code());
            }
            if usage.estimated_input_tokens.saturating_add(tokens)
                > limits.estimated_input_token_cap
            {
                return Err(limits.estimated_input_token_error.code());
            }
        }
        Ok(())
    };
    if let Operation::Admit {
        execution_tokens,
        expires_at,
    } = request.operation
    {
        if let Some(record) = record {
            return Ok(record.clone());
        }
        if request.day != now / 86400
            || expires_at <= now
            || expires_at > now + 660
            || execution_tokens == 0
            || execution_tokens > MAX_EXECUTION_INPUT_TOKENS
        {
            return Err("invalid_execution_allowance");
        }
        check(1, 0)?;
        return Ok(Record {
            subject: request.subject.clone(),
            profile: request.profile,
            day: request.day,
            expires_at,
            execution_tokens,
            finished: false,
            attempts: Vec::new(),
        });
    }
    let mut next = record.ok_or("accounting_not_found")?.clone();
    match &request.operation {
        Operation::Finish => next.finish(),
        Operation::Receipt { attempt, usage } => {
            let entry = next
                .attempts
                .iter_mut()
                .find(|a| a.id == *attempt)
                .ok_or("attempt_not_found")?;
            if entry.state == AttemptState::Dispatched {
                entry.state = AttemptState::Reported;
                entry.usage = Some(usage.clone());
            } else if entry.usage.as_ref() != Some(usage) {
                return Err("receipt_conflict");
            }
        }
        Operation::Reserve {
            attempt,
            input_tokens,
        } => {
            if next.finished || now >= next.expires_at {
                return Err("execution_expired");
            }
            if let Some(entry) = next.attempts.iter().find(|a| a.id == *attempt) {
                if entry.input_tokens != *input_tokens || entry.state != AttemptState::Reserved {
                    return Err("attempt_already_dispatched");
                }
                return Ok(next);
            }
            if *attempt as usize >= MAX_ATTEMPTS
                || next.attempts.len() >= MAX_ATTEMPTS
                || *input_tokens == 0
                || next
                    .charged()
                    .estimated_input_tokens
                    .saturating_add(*input_tokens)
                    > next.execution_tokens
            {
                return Err("execution_allowance_exhausted");
            }
            check(0, *input_tokens)?;
            next.attempts.push(Attempt {
                id: *attempt,
                input_tokens: *input_tokens,
                state: AttemptState::Reserved,
                usage: None,
            });
        }
        Operation::Dispatch { attempt } => {
            if next.finished || now >= next.expires_at {
                return Err("execution_expired");
            }
            let entry = next
                .attempts
                .iter_mut()
                .find(|a| a.id == *attempt)
                .ok_or("attempt_not_found")?;
            // A lost dispatch receipt is conservative unknown spend, never a
            // permission to invoke the provider a second time with this ID.
            if entry.state != AttemptState::Reserved {
                return Err("attempt_already_dispatched");
            }
            entry.state = AttemptState::Dispatched;
        }
        Operation::Admit { .. } => unreachable!(),
    }
    Ok(next)
}
