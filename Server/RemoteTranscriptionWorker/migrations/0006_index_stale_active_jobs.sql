-- 2026-08-19 stranded-job repair: the hourly sweeper also lists active-work
-- states that carry no state deadline (source_matched, probing, reserved,
-- chunking, transcribing, stitching) once their D1 updated_at — which moves
-- only on state transitions — is older than the sweeper's active-work
-- threshold, and nudges each one's Durable Object so a job whose alarm turn
-- died (CPU-limit kill, lost alarm) is repaired without waiting for the app
-- to poll. Partial like migration 0005 so terminal jobs stay out of the
-- sweep index; `state` leads the key because SQLite's planner drops the
-- 0005-shaped `(updated_at, job_id)` partial index for an eighth OR arm and
-- scans instead, whereas probing `state = ?` per IN value keeps the whole
-- sweep a MULTI-INDEX OR (pinned by storage.rs's EXPLAIN QUERY PLAN test).
-- The state list is repeated literally in storage.rs, whose byte-identity
-- test pins the two together.
CREATE INDEX IF NOT EXISTS idx_jobs_sweep_active_work
  ON jobs (state, updated_at, job_id)
  WHERE state IN ('source_matched', 'probing', 'reserved', 'chunking', 'transcribing', 'stitching');
