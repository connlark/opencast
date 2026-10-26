-- Retire the five-minute polling switch's seed row from 0001 (data only).
-- Apply once as owner AFTER the Worker release whose claim no longer reads the
-- row; until then the row is inert (the old claim read it COALESCEd to 0).
-- n_control has a plain name key and no dependent CHECK, foreign key or
-- trigger, so no catalog digest changes. Idempotent: a second run deletes none.
BEGIN;

DELETE FROM opencast.n_control WHERE name = 'five_minute_polling';

COMMIT;
