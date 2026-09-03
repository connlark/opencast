//! Credit authority seam (parent plan decision: the JSON service contract the
//! future PurchaseWorker implements). The boundary is service-shaped so pass
//! 1+ can swap in a `PURCHASE_WORKER` service binding without changing the
//! job DO's calls:
//!
//! - `bootstrap(account_id)` -> balance (creates the account/grant if new)
//! - `balance(account_id)` -> balance
//! - `reserve(account_id, job_id, seconds)` -> balance; idempotent by job_id
//! - `settle(account_id, job_id)` -> (); idempotent; only a reserved
//!   reservation settles
//! - `release(account_id, job_id)` -> (); idempotent; releasing after settle
//!   is a no-op
//!
//! `settle`/`release` route by `job_id`; the account id rides along so
//! PurchaseWorker can repair a hold whose `reservation_index` row was never
//! written (the DO admits before the index write). The dev authority routes
//! purely by `job_id` and ignores it.
//!
//! Integer seconds everywhere; stable error codes below. Development uses only
//! `DevCreditAuthority`, which exists exclusively in the development lane and
//! enforces real reserve/settle/release semantics against D1 so the job
//! state machine and the "no model call before successful reservation"
//! invariant are exercised honestly.

use crate::storage;
use crate::types::Balance;
use worker::{D1Database, Env, Fetcher, Headers, Method, Request, RequestInit, Response};

pub const PURCHASE_WORKER_BINDING: &str = "PURCHASE_WORKER";
const PURCHASE_INTERNAL_ORIGIN: &str = "https://opencast-purchase.internal";

pub const CREDIT_ERROR_INSUFFICIENT: &str = "insufficient_credits";
pub const CREDIT_ERROR_RESERVATION_NOT_FOUND: &str = "reservation_not_found";
pub const CREDIT_ERROR_CONFLICT: &str = "reservation_conflict";
/// PW-3: a reserve replay for an existing job carried different seconds — a
/// defect signal (job ids are single-use). Internal RTW↔PurchaseWorker seam
/// only; step_reserve maps it to the existing internal-failure path so no
/// new shape ever reaches an app client.
pub const CREDIT_ERROR_SECONDS_MISMATCH: &str = "reservation_seconds_mismatch";
pub const CREDIT_ERROR_INTERNAL: &str = "credit_internal_error";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CreditError {
    Insufficient,
    ReservationNotFound,
    Conflict(String),
    SecondsMismatch,
    Internal(String),
}

impl CreditError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Insufficient => CREDIT_ERROR_INSUFFICIENT,
            Self::ReservationNotFound => CREDIT_ERROR_RESERVATION_NOT_FOUND,
            Self::Conflict(_) => CREDIT_ERROR_CONFLICT,
            Self::SecondsMismatch => CREDIT_ERROR_SECONDS_MISMATCH,
            Self::Internal(_) => CREDIT_ERROR_INTERNAL,
        }
    }
}

pub struct DevCreditAuthority {
    db: D1Database,
    grant_seconds: i64,
}

impl DevCreditAuthority {
    pub fn new(db: D1Database, grant_seconds: i64) -> Self {
        Self { db, grant_seconds }
    }

    pub async fn bootstrap(&self, account_id: &str, now: i64) -> Result<Balance, CreditError> {
        storage::ensure_dev_credit_account(&self.db, account_id, self.grant_seconds, now)
            .await
            .map_err(internal)?;
        self.balance(account_id, now).await
    }

    pub async fn balance(&self, account_id: &str, now: i64) -> Result<Balance, CreditError> {
        storage::ensure_dev_credit_account(&self.db, account_id, self.grant_seconds, now)
            .await
            .map_err(internal)?;
        let row = storage::dev_credit_account(&self.db, account_id)
            .await
            .map_err(internal)?
            .ok_or_else(|| CreditError::Internal("credit account missing".to_string()))?;
        Ok(Balance {
            available_seconds: row.available_seconds,
            reserved_seconds: row.reserved_seconds,
            debt_seconds: 0,
        })
    }

    /// Reserve exactly `seconds` for `job_id`. A repeated reserve for the same
    /// job returns the existing reservation instead of debiting twice.
    pub async fn reserve(
        &self,
        account_id: &str,
        job_id: &str,
        seconds: i64,
        now: i64,
    ) -> Result<Balance, CreditError> {
        if seconds <= 0 {
            return Err(CreditError::Conflict(
                "seconds must be positive".to_string(),
            ));
        }
        if let Some(existing) = storage::dev_credit_reservation(&self.db, job_id)
            .await
            .map_err(internal)?
        {
            return match existing.state.as_str() {
                "reserved" | "settled" => {
                    // PW-3 mirror of PurchaseWorker's ledger rule: a replay
                    // carrying different seconds is a defect signal, never
                    // silently honored on either side of the seam.
                    if existing.reserved_seconds != seconds {
                        return Err(CreditError::SecondsMismatch);
                    }
                    self.balance(account_id, now).await
                }
                other => Err(CreditError::Conflict(format!(
                    "reservation already {other}"
                ))),
            };
        }

        storage::ensure_dev_credit_account(&self.db, account_id, self.grant_seconds, now)
            .await
            .map_err(internal)?;
        let reserved = storage::dev_credit_reserve(&self.db, account_id, job_id, seconds, now)
            .await
            .map_err(internal)?;
        if !reserved {
            return Err(CreditError::Insufficient);
        }
        self.balance(account_id, now).await
    }

    pub async fn settle(&self, job_id: &str, now: i64) -> Result<(), CreditError> {
        let Some(reservation) = storage::dev_credit_reservation(&self.db, job_id)
            .await
            .map_err(internal)?
        else {
            return Err(CreditError::ReservationNotFound);
        };
        match reservation.state.as_str() {
            "settled" => Ok(()),
            "released" => Err(CreditError::Conflict(
                "cannot settle a released reservation".to_string(),
            )),
            _ => {
                let settled = storage::dev_credit_settle(
                    &self.db,
                    job_id,
                    &reservation.account_id,
                    reservation.reserved_seconds,
                    now,
                )
                .await
                .map_err(internal)?;
                if settled {
                    Ok(())
                } else {
                    Err(CreditError::Internal("settle did not apply".to_string()))
                }
            }
        }
    }

    /// Idempotent release. Releasing a settled reservation is a no-op: the
    /// service delivered a recoverable result, so the charge stands.
    pub async fn release(&self, job_id: &str, now: i64) -> Result<(), CreditError> {
        let Some(reservation) = storage::dev_credit_reservation(&self.db, job_id)
            .await
            .map_err(internal)?
        else {
            return Ok(());
        };
        match reservation.state.as_str() {
            "released" | "settled" => Ok(()),
            _ => {
                let released = storage::dev_credit_release(
                    &self.db,
                    job_id,
                    &reservation.account_id,
                    reservation.reserved_seconds,
                    now,
                )
                .await
                .map_err(internal)?;
                if released {
                    Ok(())
                } else {
                    Err(CreditError::Internal("release did not apply".to_string()))
                }
            }
        }
    }
}

fn internal(error: worker::Error) -> CreditError {
    CreditError::Internal(error.to_string())
}

/// Client for the private PurchaseWorker service binding (schema-1 JSON on
/// `/internal/v1/*`). Seam methods mirror `DevCreditAuthority`; the raw
/// pass-through (`call_raw`) carries bootstrap/redeem/notification bodies the
/// gateway forwards verbatim.
pub struct PurchaseAuthority {
    fetcher: Fetcher,
}

#[derive(serde::Deserialize)]
struct BalanceEnvelope {
    balance: Balance,
}

#[derive(serde::Deserialize)]
struct PurchaseErrorBody {
    #[serde(default)]
    error: String,
    #[serde(default)]
    detail: Option<String>,
}

impl PurchaseAuthority {
    pub fn from_env(env: &Env) -> std::result::Result<Self, CreditError> {
        let fetcher = env
            .service(PURCHASE_WORKER_BINDING)
            .map_err(|_| CreditError::Internal("PURCHASE_WORKER binding missing".to_string()))?;
        Ok(Self { fetcher })
    }

    /// POST a JSON body to a PurchaseWorker internal route and return the raw
    /// response (status + body untouched) for gateway pass-through surfaces.
    pub async fn call_raw(&self, path: &str, body: String) -> worker::Result<Response> {
        let headers = Headers::new();
        headers.set("content-type", "application/json; charset=utf-8")?;
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_headers(headers)
            .with_body(Some(body.into()));
        let request = Request::new_with_init(&format!("{PURCHASE_INTERNAL_ORIGIN}{path}"), &init)?;
        self.fetcher.fetch_request(request).await
    }

    async fn call_seam(
        &self,
        path: &str,
        body: serde_json::Value,
    ) -> std::result::Result<Balance, CreditError> {
        let mut response = self
            .call_raw(path, body.to_string())
            .await
            .map_err(internal)?;
        let status = response.status_code();
        let text = response.text().await.map_err(internal)?;
        if (200..300).contains(&status) {
            let envelope: BalanceEnvelope = serde_json::from_str(&text).map_err(|error| {
                CreditError::Internal(format!("purchase response decode: {error}"))
            })?;
            return Ok(envelope.balance);
        }
        let error: PurchaseErrorBody = serde_json::from_str(&text).unwrap_or(PurchaseErrorBody {
            error: String::new(),
            detail: None,
        });
        Err(match error.error.as_str() {
            CREDIT_ERROR_INSUFFICIENT => CreditError::Insufficient,
            CREDIT_ERROR_RESERVATION_NOT_FOUND => CreditError::ReservationNotFound,
            CREDIT_ERROR_CONFLICT => {
                CreditError::Conflict(error.detail.unwrap_or_else(|| "conflict".to_string()))
            }
            CREDIT_ERROR_SECONDS_MISMATCH => CreditError::SecondsMismatch,
            other => CreditError::Internal(format!("purchase {status}: {other}")),
        })
    }

    pub async fn balance(&self, account_id: &str) -> std::result::Result<Balance, CreditError> {
        self.call_seam(
            "/internal/v1/balance",
            serde_json::json!({ "schema_version": 1, "account_id": account_id }),
        )
        .await
    }

    pub async fn reserve(
        &self,
        account_id: &str,
        job_id: &str,
        seconds: i64,
    ) -> std::result::Result<Balance, CreditError> {
        self.call_seam(
            "/internal/v1/reserve",
            serde_json::json!({
                "schema_version": 1,
                "account_id": account_id,
                "job_id": job_id,
                "seconds": seconds,
            }),
        )
        .await
    }

    pub async fn settle(
        &self,
        account_id: &str,
        job_id: &str,
    ) -> std::result::Result<(), CreditError> {
        self.call_seam(
            "/internal/v1/settle",
            serde_json::json!({
                "schema_version": 1,
                "account_id": account_id,
                "job_id": job_id,
            }),
        )
        .await
        .map(|_| ())
    }

    /// Idempotent; an unknown job is a successful no-op (mirrors the dev
    /// authority), and the 200 body then carries no balance.
    pub async fn release(
        &self,
        account_id: &str,
        job_id: &str,
    ) -> std::result::Result<(), CreditError> {
        let mut response = self
            .call_raw(
                "/internal/v1/release",
                serde_json::json!({
                    "schema_version": 1,
                    "account_id": account_id,
                    "job_id": job_id,
                })
                .to_string(),
            )
            .await
            .map_err(internal)?;
        let status = response.status_code();
        if (200..300).contains(&status) {
            return Ok(());
        }
        let text = response.text().await.map_err(internal)?;
        Err(CreditError::Internal(format!(
            "purchase release {status}: {}",
            text.chars().take(200).collect::<String>()
        )))
    }
}

/// The backend behind the job DO's credit seam. Same call sites, selected by
/// `AppConfig::credit_backend` (fail-closed in config.rs).
pub enum CreditAuthority {
    Dev(DevCreditAuthority),
    Purchase(PurchaseAuthority),
}

impl CreditAuthority {
    pub fn from_env(env: &Env, config: &crate::config::AppConfig) -> worker::Result<Self> {
        match config.credit_backend {
            crate::config::CreditBackend::Dev => {
                // Defense in depth: config validation already forbids this
                // outside the development lane.
                if !config.is_development_lane() {
                    return Err(worker::Error::RustError(
                        "dev credit authority unavailable outside development lane".to_string(),
                    ));
                }
                Ok(Self::Dev(DevCreditAuthority::new(
                    env.d1(crate::worker_app::TRANSCRIPTION_DB)?,
                    config.dev_credit_grant_seconds,
                )))
            }
            crate::config::CreditBackend::Purchase => Ok(Self::Purchase(
                PurchaseAuthority::from_env(env)
                    .map_err(|error| worker::Error::RustError(format!("{error:?}")))?,
            )),
        }
    }

    pub async fn balance(
        &self,
        account_id: &str,
        now: i64,
    ) -> std::result::Result<Balance, CreditError> {
        match self {
            Self::Dev(dev) => dev.balance(account_id, now).await,
            Self::Purchase(purchase) => purchase.balance(account_id).await,
        }
    }

    pub async fn reserve(
        &self,
        account_id: &str,
        job_id: &str,
        seconds: i64,
        now: i64,
    ) -> std::result::Result<Balance, CreditError> {
        match self {
            Self::Dev(dev) => dev.reserve(account_id, job_id, seconds, now).await,
            Self::Purchase(purchase) => purchase.reserve(account_id, job_id, seconds).await,
        }
    }

    pub async fn settle(
        &self,
        account_id: &str,
        job_id: &str,
        now: i64,
    ) -> std::result::Result<(), CreditError> {
        match self {
            Self::Dev(dev) => dev.settle(job_id, now).await,
            Self::Purchase(purchase) => purchase.settle(account_id, job_id).await,
        }
    }

    pub async fn release(
        &self,
        account_id: &str,
        job_id: &str,
        now: i64,
    ) -> std::result::Result<(), CreditError> {
        match self {
            Self::Dev(dev) => dev.release(job_id, now).await,
            Self::Purchase(purchase) => purchase.release(account_id, job_id).await,
        }
    }
}
