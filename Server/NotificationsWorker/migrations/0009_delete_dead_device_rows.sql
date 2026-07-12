DELETE FROM devices
WHERE notifications_enabled = 0
  AND device_token = '';
