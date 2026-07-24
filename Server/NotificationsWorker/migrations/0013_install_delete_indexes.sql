-- Install deletion is user-triggered and must not scan global audit tables as
-- their retained histories grow.
CREATE INDEX IF NOT EXISTS idx_push_send_attempts_install
  ON push_send_attempts (install_id);

CREATE INDEX IF NOT EXISTS idx_secure_hello_attempts_install
  ON secure_hello_attempts (install_id);
