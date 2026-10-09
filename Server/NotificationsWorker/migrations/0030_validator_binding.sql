-- Validators are scoped to one resource (RFC 9110 §8.8.1): the URL of the hop
-- whose parsed 200 supplied etag/last_modified is stored beside them, and the
-- time of that parse bounds how long a matching strong ETag is trusted in
-- place of the body. A 304 settle refreshes neither. Additive; binaries
-- before this change ignore both columns. Apply before deploying the
-- strong-ETag shortcut.
ALTER TABLE n_feed ADD COLUMN validator_url TEXT;
ALTER TABLE n_feed ADD COLUMN validator_at INTEGER;
