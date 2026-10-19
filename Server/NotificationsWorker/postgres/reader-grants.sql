-- Owner-applied read-only role for whole-schema readbacks (the cutover tool's
-- manifest-target and its checkpoint): schema usage and SELECT on every
-- application table, nothing else. Apply last in the install order with
-- psql -v reader_role=<read-only role>; no schema change.
GRANT USAGE ON SCHEMA opencast TO :"reader_role";
GRANT SELECT ON ALL TABLES IN SCHEMA opencast TO :"reader_role";
