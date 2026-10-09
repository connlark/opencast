-- Retention and interest-expiry lookups: the observation retention DELETE's
-- outbox check (its own NOT EXISTS and the foreign-key check per deleted row)
-- and the no-interest expiry/prune selects. Columns rewritten on every poll
-- (dispatch_until, last_poll_at, lease_id) are deliberately not indexed: each
-- index entry rewrite is a billed D1 row write. Index-only; binaries requiring
-- 0028 keep working. Apply before deploying the gc.rs rewrite.
CREATE INDEX n_feed_no_interest ON n_feed(no_interest_since) WHERE no_interest_since IS NOT NULL;
CREATE INDEX n_outbox_observation ON n_outbox(observation_id);
