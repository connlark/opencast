-- The hourly orphan sweeper applies a different deadline to each active job
-- state. Partial indexes keep terminal jobs out of the sweep index while
-- allowing SQLite to use a MULTI-INDEX OR plan instead of scanning all jobs.
CREATE INDEX IF NOT EXISTS idx_jobs_sweep_staging
  ON jobs (updated_at, job_id)
  WHERE state IN ('created', 'staging_origin');

CREATE INDEX IF NOT EXISTS idx_jobs_sweep_waiting_source
  ON jobs (updated_at, job_id)
  WHERE state = 'waiting_for_device_source';

CREATE INDEX IF NOT EXISTS idx_jobs_sweep_awaiting_credits
  ON jobs (updated_at, job_id)
  WHERE state = 'awaiting_credits';

CREATE INDEX IF NOT EXISTS idx_jobs_sweep_exact_required
  ON jobs (updated_at, job_id)
  WHERE state = 'exact_upload_required';

CREATE INDEX IF NOT EXISTS idx_jobs_sweep_exact_uploading
  ON jobs (updated_at, job_id)
  WHERE state = 'exact_uploading';

CREATE INDEX IF NOT EXISTS idx_jobs_sweep_detecting_ads
  ON jobs (updated_at, job_id)
  WHERE state = 'detecting_ads';

CREATE INDEX IF NOT EXISTS idx_jobs_sweep_results
  ON jobs (updated_at, job_id)
  WHERE state IN ('result_ready', 'delivered');
