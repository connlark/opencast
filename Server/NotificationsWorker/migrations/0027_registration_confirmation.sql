-- A fresh APNs callback may confirm the same endpoint. Keep delivery claims valid,
-- but advance the confirmation time so an older 410 cannot disable it.
-- A separate confirmation revision also fences callbacks within the same second,
-- without invalidating an in-flight delivery's endpoint generation.
ALTER TABLE n_install ADD COLUMN registration_revision INTEGER NOT NULL DEFAULT 1;
DROP TRIGGER n_device_update;
CREATE TRIGGER n_device_update AFTER UPDATE ON devices BEGIN
 UPDATE n_install SET
 token_generation=token_generation+CASE WHEN token_hash IS NOT NEW.device_token_hash
   OR enabled<>NEW.notifications_enabled OR job_capable<>NEW.job_capable
   OR OLD.device_token<>NEW.device_token OR OLD.apns_environment<>NEW.apns_environment
   OR OLD.bundle_id<>NEW.bundle_id THEN 1 ELSE 0 END,
 token_hash=NEW.device_token_hash,enabled=NEW.notifications_enabled,
 registration_revision=registration_revision+1,
 job_capable=NEW.job_capable,registered_at=MAX(registered_at,NEW.last_seen_at)
 WHERE install_id=NEW.install_id AND (token_hash=OLD.device_token_hash OR NEW.notifications_enabled=1);
END;
