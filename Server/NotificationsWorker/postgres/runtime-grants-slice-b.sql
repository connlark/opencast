-- Owner-only additive grants, after runtime-grants.sql; no role/default changes.
-- S158/S160/S162/S167: page upload, manifest expectations and publication.
GRANT UPDATE(sha256,bytes,gc_after,state,expected_pages)
 ON opencast.n_snapshot TO :"runtime_role";
-- S159 release_unused: still-reserved, empty-digest, own-lease keys only in SQL.
-- All inbound n_snapshot FKs are present; references cannot be silently removed.
GRANT DELETE ON opencast.n_snapshot TO :"runtime_role";
-- B14/S161: bulk manifest/page references. No UPDATE or DELETE of references.
GRANT INSERT ON opencast.n_snapshot_ref TO :"runtime_role";
-- B15/S171: token-dependent pending_future withdrawal only in SQL.
GRANT UPDATE(state,disposition) ON opencast.n_episode_release TO :"runtime_role";
-- A already grants feed/observation UPDATE, snapshot/observation INSERT, interest
-- absence-column UPDATE and the reads/gate lock needed by B. Catalog is read-only.
