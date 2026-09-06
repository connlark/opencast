-- Minimal content-free operational counters (jobs by outcome, Gemini token
-- totals, cap denials, billing outcomes). Values only; no identifiers or
-- content. Mirrors RemoteTranscriptionWorker migration 0003.
CREATE TABLE IF NOT EXISTS counters (
  name TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
