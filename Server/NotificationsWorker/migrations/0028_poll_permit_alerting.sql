-- Permit diagnostics and the fenced dispatcher alert state.
ALTER TABLE n_poll_stat ADD COLUMN scan_busy INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll_stat ADD COLUMN permit_reclaims INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll_dispatch ADD COLUMN stall_state TEXT NOT NULL DEFAULT 'clear';
ALTER TABLE n_poll_dispatch ADD COLUMN stall_since INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll_dispatch ADD COLUMN stall_alerted_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll_dispatch ADD COLUMN alert_armed_at INTEGER NOT NULL DEFAULT 0;
