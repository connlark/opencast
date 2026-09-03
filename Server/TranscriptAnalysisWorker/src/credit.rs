//! Credit-authority seam for the pay-gate, adapted from
//! RemoteTranscriptionWorker's `credit.rs`. Two backends behind identical call sites:
//!
//! - `DevCreditAuthority`: development-lane-only D1 fake with REAL
//!   reserve/settle/release semantics (insufficient refuses, released ids
//!   stay dead, seconds-mismatch replays fail loud) so the billing state
//!   machine is exercised honestly without PurchaseWorker.
//! - `PurchaseAuthority`: the private `PURCHASE_WORKER` service binding
//!   (schema-1 JSON on `/internal/v1/*`). The binding carries FULL debit
//!   power over any account — PurchaseWorker trusts service bindings by
//!   design — so nothing here ever takes an account id from client payload;
//!   accounts are resolved server-side from the authenticated install.
//!
//! Error strings mirror `PurchaseWorker/src/types.ts`; keep them in sync.

use serde::Deserialize;
use worker::{D1Database, D1Type, Env, Fetcher, Headers, Method, Request, RequestInit, Response};

use crate::billing::CreditBackend;
use crate::types::Balance;

pub const PURCHASE_WORKER_BINDING: &str = "PURCHASE_WORKER";
const PURCHASE_INTERNAL_ORIGIN: &str = "https://opencast-purchase.internal";

pub const CREDIT_ERROR_INSUFFICIENT: &str = "insufficient_credits";
pub const CREDIT_ERROR_RESERVATION_NOT_FOUND: &str = "reservation_not_found";
pub const CREDIT_ERROR_CONFLICT: &str = "reservation_conflict";
pub const CREDIT_ERROR_SECONDS_MISMATCH: &str = "reservation_seconds_mismatch";
pub const CREDIT_ERROR_ACCOUNT_NOT_FOUND: &str = "account_not_found";
pub const CREDIT_ERROR_INTERNAL: &str = "credit_internal_error";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CreditError {
    Insufficient,
    ReservationNotFound,
    /// PurchaseWorker does not know the account the stored install link
    /// names (e.g. a link minted against a different backend). Typed so the
    /// gateway can answer `bootstrap_required` — a re-bootstrap repairs the
    /// link — instead of a dead-end 503.
    AccountNotFound,
    Conflict(String),
    SecondsMismatch,
    Internal(String),
}

impl CreditError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Insufficient => CREDIT_ERROR_INSUFFICIENT,
            Self::ReservationNotFound => CREDIT_ERROR_RESERVATION_NOT_FOUND,
            Self::AccountNotFound => CREDIT_ERROR_ACCOUNT_NOT_FOUND,
            Self::Conflict(_) => CREDIT_ERROR_CONFLICT,
            Self::SecondsMismatch => CREDIT_ERROR_SECONDS_MISMATCH,
            Self::Internal(_) => CREDIT_ERROR_INTERNAL,
        }
    }
}

fn internal(error: worker::Error) -> CreditError {
    CreditError::Internal(error.to_string())
}

// --- D1 helpers (install links + dev fake) ----------------------------------

use opencast_app_attest_core::app_attest_storage::d1_i64;

#[derive(Deserialize)]
struct TextRow {
    value: String,
}

#[derive(Debug, Deserialize)]
struct DevCreditAccountRow {
    available_seconds: i64,
    reserved_seconds: i64,
}

#[derive(Debug, Deserialize)]
struct DevCreditReservationRow {
    account_id: String,
    reserved_seconds: i64,
    state: String,
}

/// Only reads links established by a verified bootstrap — `None` means the
/// caller must bootstrap first (typed `bootstrap_required` upstream).
pub async fn account_for_install(
    db: &D1Database,
    install_id: &str,
) -> worker::Result<Option<String>> {
    let row = db
        .prepare(
            "SELECT account_id AS value FROM install_account_links \
             WHERE install_id = ?1 LIMIT 1",
        )
        .bind_refs(&[D1Type::Text(install_id)])?
        .first::<TextRow>(None)
        .await?;
    Ok(row.map(|row| row.value))
}

/// Upsert that overwrites: PurchaseWorker is authoritative for identity, so
/// a re-bootstrap that resolves to a different account re-points the link.
pub async fn link_install_account(
    db: &D1Database,
    install_id: &str,
    account_id: &str,
    now: i64,
) -> worker::Result<()> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(account_id),
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO install_account_links (install_id, account_id, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT(install_id) DO UPDATE SET \
           account_id = excluded.account_id, \
           updated_at = excluded.updated_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;
    Ok(())
}

/// First-writer-wins claim for the dev fake's install-keyed accounts:
/// concurrent bootstraps of the same install must converge on ONE account,
/// so the insert never overwrites and the caller re-reads the winning link.
pub async fn claim_install_account(
    db: &D1Database,
    install_id: &str,
    candidate_account_id: &str,
    now: i64,
) -> worker::Result<String> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(candidate_account_id),
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO install_account_links (install_id, account_id, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT(install_id) DO NOTHING",
    )
    .bind_refs(&args)?
    .run()
    .await?;
    Ok(account_for_install(db, install_id)
        .await?
        .unwrap_or_else(|| candidate_account_id.to_string()))
}

async fn ensure_dev_credit_account(
    db: &D1Database,
    account_id: &str,
    grant_seconds: i64,
    now: i64,
) -> worker::Result<()> {
    let args = [
        D1Type::Text(account_id),
        d1_i64(grant_seconds)?,
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO dev_credit_accounts \
         (account_id, available_seconds, reserved_seconds, consumed_seconds, created_at, updated_at) \
         VALUES (?1, ?2, 0, 0, ?3, ?4) \
         ON CONFLICT(account_id) DO NOTHING",
    )
    .bind_refs(&args)?
    .run()
    .await?;
    Ok(())
}

async fn dev_credit_account(
    db: &D1Database,
    account_id: &str,
) -> worker::Result<Option<DevCreditAccountRow>> {
    db.prepare(
        "SELECT available_seconds, reserved_seconds \
         FROM dev_credit_accounts WHERE account_id = ?1 LIMIT 1",
    )
    .bind_refs(&[D1Type::Text(account_id)])?
    .first::<DevCreditAccountRow>(None)
    .await
}

async fn dev_credit_reservation(
    db: &D1Database,
    job_id: &str,
) -> worker::Result<Option<DevCreditReservationRow>> {
    db.prepare(
        "SELECT account_id, reserved_seconds, state \
         FROM dev_credit_reservations WHERE job_id = ?1 LIMIT 1",
    )
    .bind_refs(&[D1Type::Text(job_id)])?
    .first::<DevCreditReservationRow>(None)
    .await
}

/// Debits available balance and records the reservation in one atomic D1
/// batch. The INSERT is guarded on the UPDATE having changed exactly one row
/// (`changes() = 1`), so an insufficient balance changes nothing.
async fn dev_credit_reserve(
    db: &D1Database,
    account_id: &str,
    job_id: &str,
    seconds: i64,
    now: i64,
) -> worker::Result<bool> {
    let debit = db
        .prepare(
            "UPDATE dev_credit_accounts \
             SET available_seconds = available_seconds - ?1, \
                 reserved_seconds = reserved_seconds + ?1, \
                 updated_at = ?2 \
             WHERE account_id = ?3 AND available_seconds >= ?1",
        )
        .bind_refs(&[d1_i64(seconds)?, d1_i64(now)?, D1Type::Text(account_id)])?;
    let insert = db
        .prepare(
            "INSERT INTO dev_credit_reservations \
             (job_id, account_id, reserved_seconds, state, created_at, updated_at) \
             SELECT ?1, ?2, ?3, 'reserved', ?4, ?4 \
             WHERE (SELECT changes()) = 1",
        )
        .bind_refs(&[
            D1Type::Text(job_id),
            D1Type::Text(account_id),
            d1_i64(seconds)?,
            d1_i64(now)?,
        ])?;
    db.batch(vec![debit, insert]).await?;

    Ok(dev_credit_reservation(db, job_id).await?.is_some())
}

async fn dev_credit_settle(
    db: &D1Database,
    job_id: &str,
    account_id: &str,
    seconds: i64,
    now: i64,
) -> worker::Result<bool> {
    let move_buckets = db
        .prepare(
            "UPDATE dev_credit_accounts \
             SET reserved_seconds = reserved_seconds - ?1, \
                 consumed_seconds = consumed_seconds + ?1, \
                 updated_at = ?2 \
             WHERE account_id = ?3 AND reserved_seconds >= ?1 \
             AND EXISTS (SELECT 1 FROM dev_credit_reservations \
                         WHERE job_id = ?4 AND state = 'reserved')",
        )
        .bind_refs(&[
            d1_i64(seconds)?,
            d1_i64(now)?,
            D1Type::Text(account_id),
            D1Type::Text(job_id),
        ])?;
    let mark = db
        .prepare(
            "UPDATE dev_credit_reservations \
             SET state = 'settled', updated_at = ?1 \
             WHERE job_id = ?2 AND state = 'reserved' AND (SELECT changes()) = 1",
        )
        .bind_refs(&[d1_i64(now)?, D1Type::Text(job_id)])?;
    db.batch(vec![move_buckets, mark]).await?;

    Ok(matches!(
        dev_credit_reservation(db, job_id).await?,
        Some(reservation) if reservation.state == "settled"
    ))
}

async fn dev_credit_release(
    db: &D1Database,
    job_id: &str,
    account_id: &str,
    seconds: i64,
    now: i64,
) -> worker::Result<bool> {
    let move_buckets = db
        .prepare(
            "UPDATE dev_credit_accounts \
             SET reserved_seconds = reserved_seconds - ?1, \
                 available_seconds = available_seconds + ?1, \
                 updated_at = ?2 \
             WHERE account_id = ?3 AND reserved_seconds >= ?1 \
             AND EXISTS (SELECT 1 FROM dev_credit_reservations \
                         WHERE job_id = ?4 AND state = 'reserved')",
        )
        .bind_refs(&[
            d1_i64(seconds)?,
            d1_i64(now)?,
            D1Type::Text(account_id),
            D1Type::Text(job_id),
        ])?;
    let mark = db
        .prepare(
            "UPDATE dev_credit_reservations \
             SET state = 'released', updated_at = ?1 \
             WHERE job_id = ?2 AND state = 'reserved' AND (SELECT changes()) = 1",
        )
        .bind_refs(&[d1_i64(now)?, D1Type::Text(job_id)])?;
    db.batch(vec![move_buckets, mark]).await?;

    Ok(matches!(
        dev_credit_reservation(db, job_id).await?,
        Some(reservation) if reservation.state == "released"
    ))
}

// --- Dev fake authority -----------------------------------------------------

pub struct DevCreditAuthority {
    db: D1Database,
    grant_seconds: i64,
}

impl DevCreditAuthority {
    pub fn new(db: D1Database, grant_seconds: i64) -> Self {
        Self { db, grant_seconds }
    }

    pub async fn bootstrap(&self, account_id: &str, now: i64) -> Result<Balance, CreditError> {
        ensure_dev_credit_account(&self.db, account_id, self.grant_seconds, now)
            .await
            .map_err(internal)?;
        self.balance(account_id, now).await
    }

    pub async fn balance(&self, account_id: &str, now: i64) -> Result<Balance, CreditError> {
        ensure_dev_credit_account(&self.db, account_id, self.grant_seconds, now)
            .await
            .map_err(internal)?;
        let row = dev_credit_account(&self.db, account_id)
            .await
            .map_err(internal)?
            .ok_or_else(|| CreditError::Internal("credit account missing".to_string()))?;
        Ok(Balance {
            available_seconds: row.available_seconds,
            reserved_seconds: row.reserved_seconds,
            debt_seconds: 0,
        })
    }

    /// Reserve exactly `seconds` for `job_id`. A repeated reserve for the
    /// same job returns the existing reservation instead of debiting twice;
    /// a replay carrying different seconds is a defect signal (PW-3 mirror).
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
        if let Some(existing) = dev_credit_reservation(&self.db, job_id)
            .await
            .map_err(internal)?
        {
            return match existing.state.as_str() {
                "reserved" | "settled" => {
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

        ensure_dev_credit_account(&self.db, account_id, self.grant_seconds, now)
            .await
            .map_err(internal)?;
        let reserved = dev_credit_reserve(&self.db, account_id, job_id, seconds, now)
            .await
            .map_err(internal)?;
        if !reserved {
            return Err(CreditError::Insufficient);
        }
        self.balance(account_id, now).await
    }

    pub async fn settle(&self, job_id: &str, now: i64) -> Result<(), CreditError> {
        let Some(reservation) = dev_credit_reservation(&self.db, job_id)
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
                let settled = dev_credit_settle(
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
        let Some(reservation) = dev_credit_reservation(&self.db, job_id)
            .await
            .map_err(internal)?
        else {
            return Ok(());
        };
        match reservation.state.as_str() {
            "released" | "settled" => Ok(()),
            _ => {
                let released = dev_credit_release(
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

// --- PurchaseWorker authority -----------------------------------------------

/// Client for the private PurchaseWorker service binding (schema-1 JSON on
/// `/internal/v1/*`). `call_raw` also carries the bootstrap pass-through.
pub struct PurchaseAuthority {
    fetcher: Fetcher,
}

#[derive(Deserialize)]
struct BalanceEnvelope {
    balance: Balance,
}

#[derive(Deserialize)]
struct PurchaseErrorBody {
    #[serde(default)]
    error: String,
    #[serde(default)]
    detail: Option<String>,
}

impl PurchaseAuthority {
    pub fn from_env(env: &Env) -> Result<Self, CreditError> {
        let fetcher = env
            .service(PURCHASE_WORKER_BINDING)
            .map_err(|_| CreditError::Internal("PURCHASE_WORKER binding missing".to_string()))?;
        Ok(Self { fetcher })
    }

    /// POST a JSON body to a PurchaseWorker internal route and return the
    /// raw response (status + body untouched) for pass-through surfaces.
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

    async fn call_seam(&self, path: &str, body: serde_json::Value) -> Result<Balance, CreditError> {
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
            CREDIT_ERROR_ACCOUNT_NOT_FOUND => CreditError::AccountNotFound,
            CREDIT_ERROR_CONFLICT => {
                CreditError::Conflict(error.detail.unwrap_or_else(|| "conflict".to_string()))
            }
            CREDIT_ERROR_SECONDS_MISMATCH => CreditError::SecondsMismatch,
            other => CreditError::Internal(format!("purchase {status}: {other}")),
        })
    }

    pub async fn balance(&self, account_id: &str) -> Result<Balance, CreditError> {
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
    ) -> Result<Balance, CreditError> {
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

    pub async fn settle(&self, account_id: &str, job_id: &str) -> Result<(), CreditError> {
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
    pub async fn release(&self, account_id: &str, job_id: &str) -> Result<(), CreditError> {
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

// --- Selected authority -----------------------------------------------------

/// The backend behind the billing call sites, selected by the validated
/// lane/backend configuration (fail-closed in `billing.rs`).
pub enum CreditAuthority {
    Dev(DevCreditAuthority),
    Purchase(PurchaseAuthority),
}

impl CreditAuthority {
    pub fn from_env(
        env: &Env,
        backend: CreditBackend,
        lane: &str,
        dev_grant_seconds: i64,
    ) -> worker::Result<Self> {
        match backend {
            CreditBackend::Dev => {
                // Defense in depth: config validation already forbids this
                // outside the development lane.
                if lane != crate::billing::LANE_DEVELOPMENT {
                    return Err(worker::Error::RustError(
                        "dev credit authority unavailable outside development lane".to_string(),
                    ));
                }
                Ok(Self::Dev(DevCreditAuthority::new(
                    env.d1(crate::worker_app::TRANSCRIPT_ANALYSIS_DB)?,
                    dev_grant_seconds,
                )))
            }
            CreditBackend::Purchase => Ok(Self::Purchase(
                PurchaseAuthority::from_env(env)
                    .map_err(|error| worker::Error::RustError(format!("{error:?}")))?,
            )),
        }
    }

    pub async fn balance(&self, account_id: &str, now: i64) -> Result<Balance, CreditError> {
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
    ) -> Result<Balance, CreditError> {
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
    ) -> Result<(), CreditError> {
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
    ) -> Result<(), CreditError> {
        match self {
            Self::Dev(dev) => dev.release(job_id, now).await,
            Self::Purchase(purchase) => purchase.release(account_id, job_id).await,
        }
    }
}
