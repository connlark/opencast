use crate::{
    accounting, types::ErrorResponse, validation::DailyUsage, worker_app::AdAnalysisUsageLimiter,
};
use worker::{Date, Method, Request, Response, Result, SqlStorageValue};

#[derive(serde::Deserialize)]
struct Row {
    run_id: String,
    record: String,
}

impl AdAnalysisUsageLimiter {
    pub(crate) async fn account(&self, req: &mut Request) -> Result<Response> {
        if req.method() != Method::Post {
            return Response::error("method_not_allowed", 405);
        }
        let request: accounting::Request = match req.json().await {
            Ok(value) => value,
            Err(_) => return error(400, "invalid_accounting_request"),
        };
        let now = Date::now().as_millis() / 1000;
        // No external I/O or await between reading counters, deciding admission,
        // and the single-row write. Both scopes are projections of those rows.
        let expired: Vec<Row> = self
            .sql
            .exec(
                "SELECT run_id, record FROM accounted_runs WHERE finished = 0 AND expires_at <= ?",
                vec![SqlStorageValue::Integer(now as i64)],
            )?
            .to_array()?;
        for row in expired {
            let mut record: accounting::Record = serde_json::from_str(&row.record)?;
            record.finish();
            self.write_account(&row.run_id, &record)?;
        }
        let rows: Vec<Row> = self
            .sql
            .exec(
                "SELECT run_id, record FROM accounted_runs WHERE run_id = ?",
                vec![SqlStorageValue::String(request.run_id.clone())],
            )?
            .to_array()?;
        let record: Option<accounting::Record> = rows
            .first()
            .map(|row| serde_json::from_str(&row.record))
            .transpose()?;
        let mut caller = self.account_totals(Some(&request.subject))?;
        caller.request_count = caller
            .request_count
            .saturating_add(request.legacy_caller.request_count);
        caller.estimated_input_tokens = caller
            .estimated_input_tokens
            .saturating_add(request.legacy_caller.estimated_input_tokens);
        let mut global = self.account_totals(None)?;
        let legacy_global = self.current_usage()?;
        global.request_count = global
            .request_count
            .saturating_add(legacy_global.request_count);
        global.estimated_input_tokens = global
            .estimated_input_tokens
            .saturating_add(legacy_global.estimated_input_tokens);
        if record.is_none() {
            #[derive(serde::Deserialize)]
            struct Count {
                count: u64,
            }
            let rows: Vec<Count> = self
                .sql
                .exec("SELECT COUNT(*) AS count FROM accounted_runs", None)?
                .to_array()?;
            if rows[0].count >= accounting::MAX_DAILY_RECORDS as u64 {
                return error(429, "global_capacity_exhausted");
            }
        }
        let next = match accounting::apply(record.as_ref(), &request, caller, global, now) {
            Ok(record) => record,
            Err(code) => {
                return error(
                    if code.ends_with("cap_exceeded") || code == "global_capacity_exhausted" {
                        429
                    } else {
                        503
                    },
                    code,
                )
            }
        };
        self.write_account(&request.run_id, &next)?;
        self.schedule_cleanup().await?;
        Response::from_json(&next.summary())
    }

    fn write_account(&self, id: &str, record: &accounting::Record) -> Result<()> {
        let charged = record.charged();
        self.sql.exec(
            "INSERT INTO accounted_runs (run_id, subject, request_count, input_tokens, expires_at, finished, record)
             VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(run_id) DO UPDATE SET
             request_count=excluded.request_count, input_tokens=excluded.input_tokens,
             finished=excluded.finished, record=excluded.record",
            vec![SqlStorageValue::String(id.into()), SqlStorageValue::String(record.subject.clone()),
                SqlStorageValue::Integer(charged.request_count as i64), SqlStorageValue::Integer(charged.estimated_input_tokens as i64),
                SqlStorageValue::Integer(record.expires_at as i64), SqlStorageValue::Integer(i64::from(record.finished)),
                SqlStorageValue::String(serde_json::to_string(record)?)],
        )?;
        Ok(())
    }

    fn account_totals(&self, subject: Option<&str>) -> Result<DailyUsage> {
        let (query, params) = if let Some(subject) = subject {
            ("SELECT COALESCE(SUM(request_count), 0) AS request_count, COALESCE(SUM(input_tokens), 0) AS estimated_input_tokens FROM accounted_runs WHERE subject = ?",
                vec![SqlStorageValue::String(subject.into())])
        } else {
            ("SELECT COALESCE(SUM(request_count), 0) AS request_count, COALESCE(SUM(input_tokens), 0) AS estimated_input_tokens FROM accounted_runs", vec![])
        };
        let rows: Vec<DailyUsage> = self.sql.exec(query, params)?.to_array()?;
        Ok(rows.into_iter().next().unwrap_or_default())
    }
}

fn error(status: u16, code: &str) -> Result<Response> {
    Ok(Response::from_json(&ErrorResponse::new(code))?.with_status(status))
}
