-- Minimal content-free operational counters (jobs by outcome, seconds,
-- match/mismatch, AI attempts). Values only; no identifiers or content.
CREATE TABLE IF NOT EXISTS counters (
  name TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
