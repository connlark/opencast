-- Owner-only additive identity/enrollment/subscription privileges.
-- Apply after the common schema and baseline polling grants.
-- All deletes retain their original installation-bound semantic predicates.
-- No retention, reference deletion, snapshot GC or role/default authority.
-- Source statement witnesses use the original D1 revision 5bef4fb5.
-- S001 Server/AppAttestCore/src/app_attest_storage.rs:46; S002 Server/AppAttestCore/src/app_attest_storage.rs:94; S007 Server/AppAttestCore/src/app_attest_storage.rs:168; S009 Server/AppAttestCore/src/app_attest_storage.rs:188; S277 Server/NotificationsWorker/src/storage.rs:622; S279 Server/NotificationsWorker/src/storage.rs:635
GRANT SELECT(challenge_id,challenge_hash,purpose,install_id,created_at,expires_at,consumed_at) ON opencast.app_attest_challenges TO :"runtime_role";
-- S001 Server/AppAttestCore/src/app_attest_storage.rs:46
GRANT INSERT(challenge_id,challenge_hash,purpose,install_id,created_at,expires_at) ON opencast.app_attest_challenges TO :"runtime_role";
-- S009 Server/AppAttestCore/src/app_attest_storage.rs:188
GRANT UPDATE(consumed_at) ON opencast.app_attest_challenges TO :"runtime_role";
-- S007 Server/AppAttestCore/src/app_attest_storage.rs:168; S277 Server/NotificationsWorker/src/storage.rs:622
-- Exact D1 predicate: DELETE FROM app_attest_challenges WHERE install_id = ?1
-- Exact D1 predicate: DELETE FROM app_attest_challenges WHERE install_id = ?1
GRANT DELETE ON opencast.app_attest_challenges TO :"runtime_role";
-- S003 Server/AppAttestCore/src/app_attest_storage.rs:116; S004 Server/AppAttestCore/src/app_attest_storage.rs:129
GRANT SELECT(source_token,window_start,request_count,updated_at) ON opencast.app_attest_challenge_source_buckets TO :"runtime_role";
-- S003 Server/AppAttestCore/src/app_attest_storage.rs:116
GRANT INSERT(source_token,window_start,request_count,updated_at) ON opencast.app_attest_challenge_source_buckets TO :"runtime_role";
-- S003 Server/AppAttestCore/src/app_attest_storage.rs:116
GRANT UPDATE(request_count,updated_at) ON opencast.app_attest_challenge_source_buckets TO :"runtime_role";
-- S008 Server/AppAttestCore/src/app_attest_storage.rs:169; S011 Server/AppAttestCore/src/app_attest_storage.rs:247; S012 Server/AppAttestCore/src/app_attest_storage.rs:265; S013 Server/AppAttestCore/src/app_attest_storage.rs:294; S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123; S252 Server/NotificationsWorker/src/storage.rs:250; S253 Server/NotificationsWorker/src/storage.rs:272; S278 Server/NotificationsWorker/src/storage.rs:623; S279 Server/NotificationsWorker/src/storage.rs:635
GRANT SELECT(install_id,key_id,public_key,sign_counter,app_id,environment,created_at,last_used_at) ON opencast.app_attest_keys TO :"runtime_role";
-- S279 Server/NotificationsWorker/src/storage.rs:635
GRANT INSERT(install_id,key_id,public_key,sign_counter,app_id,environment,created_at,last_used_at) ON opencast.app_attest_keys TO :"runtime_role";
-- S013 Server/AppAttestCore/src/app_attest_storage.rs:294; S279 Server/NotificationsWorker/src/storage.rs:635
GRANT UPDATE(public_key,app_id,environment,last_used_at,sign_counter) ON opencast.app_attest_keys TO :"runtime_role";
-- S008 Server/AppAttestCore/src/app_attest_storage.rs:169; S278 Server/NotificationsWorker/src/storage.rs:623
-- Exact D1 predicate: DELETE FROM app_attest_keys WHERE install_id = ?1
-- Exact D1 predicate: DELETE FROM app_attest_keys WHERE install_id = ?1
GRANT DELETE ON opencast.app_attest_keys TO :"runtime_role";
-- S246 Server/NotificationsWorker/src/storage.rs:173; S247 Server/NotificationsWorker/src/storage.rs:180; S252 Server/NotificationsWorker/src/storage.rs:250; S254 Server/NotificationsWorker/src/storage.rs:293; S255 Server/NotificationsWorker/src/storage.rs:321; S256 Server/NotificationsWorker/src/storage.rs:359; S257 Server/NotificationsWorker/src/storage.rs:377; S276 Server/NotificationsWorker/src/storage.rs:620
GRANT SELECT(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,last_seen_at,job_capable) ON opencast.devices TO :"runtime_role";
-- S252 Server/NotificationsWorker/src/storage.rs:250
GRANT INSERT(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at,job_capable) ON opencast.devices TO :"runtime_role";
-- S252 Server/NotificationsWorker/src/storage.rs:250; S254 Server/NotificationsWorker/src/storage.rs:293
GRANT UPDATE(key_id,device_token,apns_environment,bundle_id,notifications_enabled,job_capable,last_seen_at) ON opencast.devices TO :"runtime_role";
-- S247 Server/NotificationsWorker/src/storage.rs:180; S253 Server/NotificationsWorker/src/storage.rs:272; S276 Server/NotificationsWorker/src/storage.rs:620
-- Exact D1 predicate: DELETE FROM devices WHERE install_id = ?1 AND apns_environment = ?2 AND bundle_id = ?3 AND device_token_hash <> ?4
-- Exact D1 predicate: DELETE FROM devices WHERE install_id = ?1 AND apns_environment = ?2 AND bundle_id = ?3 AND device_token_hash <> ?4 AND EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=?1 AND key_id=?5)
-- Exact D1 predicate: DELETE FROM devices WHERE install_id = ?1
GRANT DELETE ON opencast.devices TO :"runtime_role";
-- S015 Server/NotificationsWorker/src/delivery/db.rs:83; S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123; S252 Server/NotificationsWorker/src/storage.rs:250; S261 Server/NotificationsWorker/src/storage.rs:568; S275 Server/NotificationsWorker/src/storage.rs:619
-- Invoker trigger: n_feed_insert/n_install_insert
GRANT SELECT(install_id,feed_url,notifications_enabled,created_at,updated_at,deleted_at) ON opencast.feed_subscriptions TO :"runtime_role";
-- S239 Server/NotificationsWorker/src/storage.rs:107
GRANT INSERT(install_id,feed_url,notifications_enabled,created_at,updated_at,deleted_at) ON opencast.feed_subscriptions TO :"runtime_role";
-- S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123
GRANT UPDATE(created_at,notifications_enabled,updated_at,deleted_at) ON opencast.feed_subscriptions TO :"runtime_role";
-- S275 Server/NotificationsWorker/src/storage.rs:619
-- Exact D1 predicate: DELETE FROM feed_subscriptions WHERE install_id = ?1
GRANT DELETE ON opencast.feed_subscriptions TO :"runtime_role";
-- S238 Server/NotificationsWorker/src/storage.rs:98
GRANT INSERT(feed_url,source_url,created_at,updated_at) ON opencast.n_feed_catalog TO :"runtime_role";
-- S015 Server/NotificationsWorker/src/delivery/db.rs:83
-- Invoker trigger: n_catalog_enrolled
GRANT UPDATE(admission_health_json) ON opencast.n_feed_catalog TO :"runtime_role";
-- S015 Server/NotificationsWorker/src/delivery/db.rs:83
GRANT INSERT(feed_id,canonical_url,epoch,due_at) ON opencast.n_feed TO :"runtime_role";
-- S252 Server/NotificationsWorker/src/storage.rs:250
-- Invoker trigger: n_device_insert
GRANT INSERT(install_id,epoch,token_generation,token_hash,enabled,job_capable,registered_at) ON opencast.n_install TO :"runtime_role";
-- S247 Server/NotificationsWorker/src/storage.rs:180; S252 Server/NotificationsWorker/src/storage.rs:250; S253 Server/NotificationsWorker/src/storage.rs:272; S254 Server/NotificationsWorker/src/storage.rs:293; S276 Server/NotificationsWorker/src/storage.rs:620
-- Invoker trigger: n_device_insert/n_device_update/n_device_delete
GRANT UPDATE(enabled,token_hash,token_generation,job_capable,registered_at,registration_revision) ON opencast.n_install TO :"runtime_role";
-- S272 Server/NotificationsWorker/src/storage.rs:615
-- Exact D1 predicate: DELETE FROM n_install WHERE install_id=?1
GRANT DELETE ON opencast.n_install TO :"runtime_role";
-- S015 Server/NotificationsWorker/src/delivery/db.rs:83; S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123; S252 Server/NotificationsWorker/src/storage.rs:250
-- Invoker trigger: n_feed_insert/n_install_insert/n_subscription_insert/n_subscription_update
GRANT INSERT(install_id,feed_id,generation,activated_at,enabled,changed_at) ON opencast.n_interest TO :"runtime_role";
-- S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123; S263 Server/NotificationsWorker/src/storage.rs:603; S275 Server/NotificationsWorker/src/storage.rs:619
-- Invoker trigger: n_subscription_update/n_subscription_delete; S263 direct changed_at
GRANT UPDATE(generation,activated_at,enabled,changed_at) ON opencast.n_interest TO :"runtime_role";
-- S270 Server/NotificationsWorker/src/storage.rs:613
-- Exact D1 predicate: DELETE FROM n_interest WHERE install_id=?1
GRANT DELETE ON opencast.n_interest TO :"runtime_role";
-- S015 Server/NotificationsWorker/src/delivery/db.rs:83
-- Invoker trigger: n_feed_insert
GRANT INSERT(install_id,feed_id,identity_key,disposition,expires_at) ON opencast.n_legacy_bridge TO :"runtime_role";
-- S271 Server/NotificationsWorker/src/storage.rs:614
GRANT SELECT(install_id) ON opencast.n_legacy_bridge TO :"runtime_role";
-- S271 Server/NotificationsWorker/src/storage.rs:614
-- Exact D1 predicate: DELETE FROM n_legacy_bridge WHERE install_id=?1
GRANT DELETE ON opencast.n_legacy_bridge TO :"runtime_role";
-- S015 Server/NotificationsWorker/src/delivery/db.rs:83; S273 Server/NotificationsWorker/src/storage.rs:616
-- Invoker trigger: n_feed_insert
GRANT SELECT(install_id,feed_url,episode_id,episode_fingerprint,apns_status,apns_error,updated_at) ON opencast.n_delivery_history TO :"runtime_role";
-- S273 Server/NotificationsWorker/src/storage.rs:616
-- Exact D1 predicate: DELETE FROM n_delivery_history WHERE install_id = ?1
GRANT DELETE ON opencast.n_delivery_history TO :"runtime_role";
-- S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123; S247 Server/NotificationsWorker/src/storage.rs:180; S252 Server/NotificationsWorker/src/storage.rs:250; S253 Server/NotificationsWorker/src/storage.rs:272; S254 Server/NotificationsWorker/src/storage.rs:293; S265 Server/NotificationsWorker/src/storage.rs:608; S275 Server/NotificationsWorker/src/storage.rs:619; S276 Server/NotificationsWorker/src/storage.rs:620
-- Invoker trigger: n_install_disable/n_interest_changed
GRANT SELECT(install_id,state,interest_key,interest_generation) ON opencast.n_delivery TO :"runtime_role";
-- S239 Server/NotificationsWorker/src/storage.rs:107; S240 Server/NotificationsWorker/src/storage.rs:123; S247 Server/NotificationsWorker/src/storage.rs:180; S252 Server/NotificationsWorker/src/storage.rs:250; S253 Server/NotificationsWorker/src/storage.rs:272; S254 Server/NotificationsWorker/src/storage.rs:293; S275 Server/NotificationsWorker/src/storage.rs:619; S276 Server/NotificationsWorker/src/storage.rs:620
-- Invoker trigger: n_install_disable/n_interest_changed
GRANT UPDATE(state,terminal_at,last_reason,lease_id,lease_until) ON opencast.n_delivery TO :"runtime_role";
-- S265 Server/NotificationsWorker/src/storage.rs:608
-- Exact D1 predicate: DELETE FROM n_delivery WHERE install_id=?1
GRANT DELETE ON opencast.n_delivery TO :"runtime_role";
-- S247 Server/NotificationsWorker/src/storage.rs:180; S252 Server/NotificationsWorker/src/storage.rs:250; S253 Server/NotificationsWorker/src/storage.rs:272; S254 Server/NotificationsWorker/src/storage.rs:293; S266 Server/NotificationsWorker/src/storage.rs:609; S267 Server/NotificationsWorker/src/storage.rs:610; S268 Server/NotificationsWorker/src/storage.rs:611; S269 Server/NotificationsWorker/src/storage.rs:612; S276 Server/NotificationsWorker/src/storage.rs:620
-- Invoker trigger: n_install_disable
GRANT SELECT(install_id,state,interest_id,operation_id,requester_ref,producer) ON opencast.n_job_interest TO :"runtime_role";
-- S247 Server/NotificationsWorker/src/storage.rs:180; S252 Server/NotificationsWorker/src/storage.rs:250; S253 Server/NotificationsWorker/src/storage.rs:272; S254 Server/NotificationsWorker/src/storage.rs:293; S276 Server/NotificationsWorker/src/storage.rs:620
-- Invoker trigger: n_install_disable
GRANT UPDATE(state) ON opencast.n_job_interest TO :"runtime_role";
-- S269 Server/NotificationsWorker/src/storage.rs:612
-- Exact D1 predicate: DELETE FROM n_job_interest WHERE install_id=?1
GRANT DELETE ON opencast.n_job_interest TO :"runtime_role";
-- S264 Server/NotificationsWorker/src/storage.rs:607
GRANT SELECT(install_id) ON opencast.n_delivery_member TO :"runtime_role";
-- S264 Server/NotificationsWorker/src/storage.rs:607
-- Exact D1 predicate: DELETE FROM n_delivery_member WHERE install_id=?1
GRANT DELETE ON opencast.n_delivery_member TO :"runtime_role";
-- S266 Server/NotificationsWorker/src/storage.rs:609
GRANT SELECT(source,event_id) ON opencast.n_group_member TO :"runtime_role";
-- S266 Server/NotificationsWorker/src/storage.rs:609
-- Exact D1 predicate: DELETE FROM n_group_member WHERE (source,event_id) IN(SELECT source,event_id FROM n_event WHERE interest_id IN(SELECT interest_id FROM n_job_interest WHERE install_id=?1))
GRANT DELETE ON opencast.n_group_member TO :"runtime_role";
-- S266 Server/NotificationsWorker/src/storage.rs:609; S267 Server/NotificationsWorker/src/storage.rs:610
GRANT SELECT(source,event_id,interest_id) ON opencast.n_event TO :"runtime_role";
-- S267 Server/NotificationsWorker/src/storage.rs:610
-- Exact D1 predicate: DELETE FROM n_event WHERE interest_id IN(SELECT interest_id FROM n_job_interest WHERE install_id=?1)
GRANT DELETE ON opencast.n_event TO :"runtime_role";
-- S268 Server/NotificationsWorker/src/storage.rs:611
GRANT SELECT(operation_id,requester_ref,producer) ON opencast.n_requester_ticket TO :"runtime_role";
-- S268 Server/NotificationsWorker/src/storage.rs:611
-- Exact D1 predicate: DELETE FROM n_requester_ticket WHERE EXISTS(SELECT 1 FROM n_job_interest j WHERE j.install_id=?1 AND j.operation_id=n_requester_ticket.operation_id AND j.requester_ref=n_requester_ticket.requester_ref AND j.producer=n_requester_ticket.producer)
GRANT DELETE ON opencast.n_requester_ticket TO :"runtime_role";
-- S262 Server/NotificationsWorker/src/storage.rs:601
GRANT INSERT(fence,expires_at) ON opencast.n_deleted_install TO :"runtime_role";
-- S262 Server/NotificationsWorker/src/storage.rs:601
GRANT SELECT(fence,expires_at) ON opencast.n_deleted_install TO :"runtime_role";
-- S243 Server/NotificationsWorker/src/storage.rs:160; S259 Server/NotificationsWorker/src/storage.rs:464; S260 Server/NotificationsWorker/src/storage.rs:505; S274 Server/NotificationsWorker/src/storage.rs:618
-- S241: exact persisted attempt fields for operation-specific readback after Unknown.
GRANT SELECT(attempt_id,install_id,key_id,host,accepted,error_code,created_at) ON opencast.feed_admission_attempts TO :"runtime_role";
-- S241 Server/NotificationsWorker/src/storage.rs:127
GRANT INSERT(attempt_id,install_id,key_id,host,accepted,error_code,created_at) ON opencast.feed_admission_attempts TO :"runtime_role";
-- S274 Server/NotificationsWorker/src/storage.rs:618
-- Exact D1 predicate: DELETE FROM feed_admission_attempts WHERE install_id = ?1
GRANT DELETE ON opencast.feed_admission_attempts TO :"runtime_role";
-- S250 Server/NotificationsWorker/src/storage.rs:213
GRANT INSERT(attempt_id,install_id,key_id,accepted,error_code,created_at) ON opencast.secure_hello_attempts TO :"runtime_role";
-- S249 Server/NotificationsWorker/src/storage.rs:189
-- S250: exact persisted attempt fields for operation-specific readback after Unknown.
GRANT SELECT(attempt_id,install_id,key_id,accepted,error_code,created_at) ON opencast.secure_hello_attempts TO :"runtime_role";
-- S249 Server/NotificationsWorker/src/storage.rs:189
-- Exact D1 predicate: DELETE FROM secure_hello_attempts WHERE install_id = ?1
GRANT DELETE ON opencast.secure_hello_attempts TO :"runtime_role";
-- S258 Server/NotificationsWorker/src/storage.rs:422
GRANT INSERT(attempt_id,install_id,device_token_hash,apns_environment,apns_status,apns_id,apns_error,created_at) ON opencast.push_send_attempts TO :"runtime_role";
-- S248 Server/NotificationsWorker/src/storage.rs:187
-- S258: exact persisted attempt fields for operation-specific readback after Unknown.
GRANT SELECT(attempt_id,install_id,device_token_hash,apns_environment,apns_status,apns_id,apns_error,created_at) ON opencast.push_send_attempts TO :"runtime_role";
-- S248 Server/NotificationsWorker/src/storage.rs:187
-- Exact D1 predicate: DELETE FROM push_send_attempts WHERE install_id = ?1
GRANT DELETE ON opencast.push_send_attempts TO :"runtime_role";
