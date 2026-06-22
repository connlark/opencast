UPDATE devices
SET
  device_token = '',
  notifications_enabled = 0
WHERE notifications_enabled = 1
  AND EXISTS (
    SELECT 1
    FROM devices newer
    WHERE newer.install_id = devices.install_id
      AND newer.apns_environment = devices.apns_environment
      AND newer.bundle_id = devices.bundle_id
      AND newer.notifications_enabled = 1
      AND (
        newer.last_seen_at > devices.last_seen_at
        OR (
          newer.last_seen_at = devices.last_seen_at
          AND newer.device_token_hash > devices.device_token_hash
        )
      )
  );
