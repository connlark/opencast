//! Scheduled operational floor for remote transcription. The sweeper is
//! deliberately content-blind: it sees R2 keys, job IDs, states, and counts,
//! never transcript text, enclosure URLs, episode titles, or source hashes.

use std::collections::BTreeSet;

const SCRATCH_LIFECYCLE_SECONDS: i64 = 24 * 60 * 60;
const RESULT_LIFECYCLE_SECONDS: i64 = 7 * 24 * 60 * 60;
/// Cloudflare documents that lifecycle deletion may lag the expiry time by
/// another 24 hours. Alert only after that expected deletion window passes.
const LIFECYCLE_DELETION_GRACE_SECONDS: i64 = 24 * 60 * 60;
const MAX_ALERT_JOB_IDS: usize = 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SweepReport {
    pub orphan_object_count: usize,
    pub stale_job_ids: Vec<String>,
    pub object_job_ids: Vec<String>,
    pub scan_truncated: bool,
}

impl SweepReport {
    pub fn anomaly_count(&self) -> usize {
        self.orphan_object_count + self.stale_job_ids.len() + usize::from(self.scan_truncated)
    }

    pub fn alert_job_ids(&self) -> Vec<String> {
        let mut ids = BTreeSet::new();
        for job_id in self.stale_job_ids.iter().chain(self.object_job_ids.iter()) {
            if crate::route::valid_job_id(job_id) {
                ids.insert(job_id.clone());
            }
        }
        ids.into_iter().take(MAX_ALERT_JOB_IDS).collect()
    }

    pub fn alert_message(&self) -> String {
        let ids = self.alert_job_ids();
        format!(
            "orphan_objects={} stale_jobs={} scan_truncated={} job_ids={}",
            self.orphan_object_count,
            self.stale_job_ids.len(),
            usize::from(self.scan_truncated),
            if ids.is_empty() {
                "none".to_string()
            } else {
                ids.join(",")
            }
        )
    }
}

/// Returns the age after which a lifecycle-managed object is anomalous.
/// Unknown prefixes (notably the intentionally unmanaged `debug/` fixture
/// evidence) are ignored.
pub fn expected_deletion_seconds(key: &str) -> Option<i64> {
    let lifecycle = if ["raw/", "uploads/", "chunks/", "responses/"]
        .iter()
        .any(|prefix| key.starts_with(prefix))
    {
        SCRATCH_LIFECYCLE_SECONDS
    } else if key.starts_with("results/") {
        RESULT_LIFECYCLE_SECONDS
    } else {
        return None;
    };
    Some(lifecycle + LIFECYCLE_DELETION_GRACE_SECONDS)
}

pub fn object_is_orphan(key: &str, uploaded_seconds: i64, now_seconds: i64) -> bool {
    expected_deletion_seconds(key)
        .is_some_and(|expected| uploaded_seconds.saturating_add(expected) <= now_seconds)
}

pub fn job_id_from_object_key(key: &str) -> Option<String> {
    let mut parts = key.split('/');
    let prefix = parts.next()?;
    if !matches!(
        prefix,
        "raw" | "uploads" | "chunks" | "responses" | "results"
    ) {
        return None;
    }
    let job_id = parts.next()?;
    crate::route::valid_job_id(job_id).then(|| job_id.to_string())
}

#[cfg(target_arch = "wasm32")]
mod runtime {
    use super::{job_id_from_object_key, object_is_orphan, SweepReport};
    use std::collections::BTreeSet;
    use worker::{Env, Fetch, Headers, Method, Request, RequestInit, Result};

    use crate::config::AppConfig;
    use crate::storage;

    const TRANSCRIPTION_AUDIO: &str = "TRANSCRIPTION_AUDIO";
    const TRANSCRIPTION_DB: &str = "TRANSCRIPTION_DB";
    const DEFAULT_MAX_R2_OBJECTS: usize = 5_000;
    const DEFAULT_MAX_STALE_JOBS: usize = 100;
    const R2_LIST_PAGE_SIZE: u32 = 1_000;
    const PUSHOVER_URL: &str = "https://api.pushover.net/1/messages.json";

    pub async fn run(env: &Env) -> Result<SweepReport> {
        let config = AppConfig::from_env(env).map_err(|error| {
            worker::Error::RustError(format!("sweeper lane config invalid: {}", error.error))
        })?;
        let db = env.d1(TRANSCRIPTION_DB)?;
        let bucket = env.bucket(TRANSCRIPTION_AUDIO)?;
        let now_seconds = now_seconds();
        let now_millis = now_seconds.saturating_mul(1_000);

        let max_stale_jobs =
            usize_var(env, "ORPHAN_SWEEP_MAX_STALE_JOBS", DEFAULT_MAX_STALE_JOBS).clamp(1, 1_000);
        let (stale_job_ids, stale_truncated) =
            storage::stale_job_ids(&db, &config, now_seconds, max_stale_jobs).await?;

        let max_r2_objects = usize_var(env, "ORPHAN_SWEEP_MAX_R2_OBJECTS", DEFAULT_MAX_R2_OBJECTS)
            .clamp(100, 10_000);
        let (orphan_object_count, object_job_ids, r2_truncated) =
            scan_r2(&bucket, now_millis, max_r2_objects).await?;
        let report = SweepReport {
            orphan_object_count,
            stale_job_ids,
            object_job_ids,
            scan_truncated: stale_truncated || r2_truncated,
        };

        storage::increment_counter(&db, "orphan_sweeper_runs", 1, now_seconds).await?;
        storage::increment_counter(
            &db,
            "orphan_objects_found",
            report.orphan_object_count as i64,
            now_seconds,
        )
        .await?;
        storage::increment_counter(
            &db,
            "stale_jobs_found",
            report.stale_job_ids.len() as i64,
            now_seconds,
        )
        .await?;
        storage::increment_counter(
            &db,
            "orphan_sweeper_truncated",
            i64::from(report.scan_truncated),
            now_seconds,
        )
        .await?;

        if report.anomaly_count() > 0 {
            let title = format!("OpenCast transcription alert ({})", config.lane);
            match send_pushover(env, &title, &report.alert_message()).await {
                Ok(()) => {
                    storage::increment_counter(&db, "orphan_alerts_sent", 1, now_seconds).await?;
                }
                Err(error) => {
                    storage::increment_counter(&db, "orphan_alert_failures", 1, now_seconds)
                        .await?;
                    return Err(error);
                }
            }
        }

        Ok(report)
    }

    async fn scan_r2(
        bucket: &worker::Bucket,
        now_millis: i64,
        max_objects: usize,
    ) -> Result<(usize, Vec<String>, bool)> {
        let mut scanned = 0usize;
        let mut orphan_count = 0usize;
        let mut job_ids = BTreeSet::new();
        let mut truncated = false;

        for prefix in ["raw/", "uploads/", "chunks/", "responses/", "results/"] {
            let mut cursor: Option<String> = None;
            loop {
                if scanned >= max_objects {
                    truncated = true;
                    break;
                }
                let remaining = max_objects - scanned;
                let mut list = bucket
                    .list()
                    .prefix(prefix)
                    .limit(R2_LIST_PAGE_SIZE.min(remaining as u32));
                if let Some(value) = cursor.as_deref() {
                    list = list.cursor(value);
                }
                let listed = list.execute().await?;
                let objects = listed.objects();
                scanned += objects.len();
                for object in objects {
                    let uploaded_seconds =
                        i64::try_from(object.uploaded().as_millis() / 1_000).unwrap_or(i64::MAX);
                    if object_is_orphan(&object.key(), uploaded_seconds, now_millis / 1_000) {
                        orphan_count += 1;
                        if let Some(job_id) = job_id_from_object_key(&object.key()) {
                            job_ids.insert(job_id);
                        }
                    }
                }
                if !listed.truncated() {
                    break;
                }
                let Some(next) = listed.cursor() else {
                    return Err(worker::Error::RustError(
                        "R2 list was truncated without a cursor".to_string(),
                    ));
                };
                cursor = Some(next);
            }
            if truncated {
                break;
            }
        }

        Ok((orphan_count, job_ids.into_iter().collect(), truncated))
    }

    async fn send_pushover(env: &Env, title: &str, message: &str) -> Result<()> {
        let token = env
            .secret("PUSHOVER_APP_TOKEN")
            .map_err(|_| worker::Error::RustError("PUSHOVER_APP_TOKEN missing".to_string()))?
            .to_string();
        let user = env
            .secret("PUSHOVER_USER_KEY")
            .map_err(|_| worker::Error::RustError("PUSHOVER_USER_KEY missing".to_string()))?
            .to_string();
        let body = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("token", &token)
            .append_pair("user", &user)
            .append_pair("title", title)
            .append_pair("message", message)
            .finish();
        let headers = Headers::new();
        headers.set("content-type", "application/x-www-form-urlencoded")?;
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_headers(headers)
            .with_body(Some(body.into()));
        let request = Request::new_with_init(PUSHOVER_URL, &init)?;
        let response = Fetch::Request(request).send().await?;
        if !(200..300).contains(&response.status_code()) {
            return Err(worker::Error::RustError(format!(
                "Pushover returned HTTP {}",
                response.status_code()
            )));
        }
        Ok(())
    }

    fn usize_var(env: &Env, name: &str, fallback: usize) -> usize {
        env.var(name)
            .ok()
            .and_then(|value| value.to_string().parse().ok())
            .unwrap_or(fallback)
    }

    fn now_seconds() -> i64 {
        i64::try_from(worker::Date::now().as_millis() / 1_000).unwrap_or(i64::MAX)
    }
}

#[cfg(target_arch = "wasm32")]
pub use runtime::run;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lifecycle_windows_include_cloudflare_deletion_grace() {
        assert_eq!(
            expected_deletion_seconds("raw/job/source"),
            Some(2 * 86_400)
        );
        assert_eq!(
            expected_deletion_seconds("results/job/transcript.json"),
            Some(8 * 86_400)
        );
        assert_eq!(expected_deletion_seconds("debug/job/0.json"), None);
    }

    #[test]
    fn orphan_boundary_is_inclusive_and_unknown_prefixes_are_ignored() {
        let uploaded = 1_000;
        assert!(!object_is_orphan(
            "raw/job/source",
            uploaded,
            uploaded + 2 * 86_400 - 1
        ));
        assert!(object_is_orphan(
            "raw/job/source",
            uploaded,
            uploaded + 2 * 86_400
        ));
        assert!(!object_is_orphan("debug/job/0.json", 0, i64::MAX));
    }

    #[test]
    fn object_keys_only_surface_valid_job_ids() {
        assert_eq!(
            job_id_from_object_key("chunks/job-abc_1/0.mp3").as_deref(),
            Some("job-abc_1")
        );
        assert_eq!(job_id_from_object_key("raw/../../secret"), None);
        assert_eq!(job_id_from_object_key("unknown/job/source"), None);
    }

    #[test]
    fn alert_body_is_content_free_bounded_and_deterministic() {
        let report = SweepReport {
            orphan_object_count: 3,
            stale_job_ids: vec!["job-b".to_string(), "job-a".to_string()],
            object_job_ids: vec!["job-a".to_string(), "bad/id".to_string()],
            scan_truncated: false,
        };
        assert_eq!(
            report.alert_message(),
            "orphan_objects=3 stale_jobs=2 scan_truncated=0 job_ids=job-a,job-b"
        );
    }
}
