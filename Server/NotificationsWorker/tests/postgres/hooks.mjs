// The storage hook table for the wire proxy: which fault names each test entry
// routes to the proxy (PROXY_NAMES), the matchers on the PostgreSQL text the
// Workers issue (M, the same prefixes as the entries' D1 hooks), the owner side
// writes with their affected-count rules (SIDE), and match(): the earlier
// PostgreSQL integration harness's decide(), unchanged in meaning but pure, so
// the interactive guard can ask what WOULD fire without consuming an arming (it
// re-checks the armed matchers on every unit after the interactive prefix).
// That harness's driver-armed lost-acknowledgement hook, its ledger and its
// Miniflare wrapper are gone.
export const GATE_PREFIX='SELECT 1/COUNT(*) AS guard';
// Verbatim from NotificationsWorker/src/database/postgres/slice_e.rs: the one
// shipped interactive transaction (AbandonPoisoned awaits each reply).
export const INTERACTIVE_FIRST="SELECT observation_id,reason_counts_json FROM n_observation WHERE feed_id=$1 AND state='staging' AND valid_eof=1 AND processing_failures>=10 AND (processing_token IS NULL OR processing_until<=$2) ORDER BY scan_started_at LIMIT 20";
// Application statements are everything but the transaction frame and the gate.
export const isApplication=sql=>typeof sql==='string'&&sql!=='BEGIN'&&sql!=='COMMIT'&&sql!=='ROLLBACK'&&!sql.startsWith(GATE_PREFIX);
export const M={
 claim:s=>s.startsWith('SELECT f.origin_key,f.due_at'),
 stat:s=>s.startsWith('INSERT INTO n_poll_stat'),
 redeliveryStat:s=>s.startsWith('INSERT INTO n_poll_stat(bucket,redeliveries)'),
 origin:s=>s.includes('INSERT INTO n_poll_origin'),
 publish:s=>s.startsWith('UPDATE n_feed SET observation_generation='),
 settle:s=>s.startsWith('UPDATE n_feed SET last_success_at='),
 watchdog:s=>s.includes('AS late_900'),
 checkpoint:s=>s.startsWith('UPDATE n_observation SET preparation_key='),
 manifest:s=>s.startsWith('INSERT INTO n_snapshot_ref'),
 sendAuthority:s=>s.startsWith('SELECT')&&s.includes('attempt_token_generation=(SELECT token_generation'),
 fanout:s=>s.startsWith('UPDATE n_event SET fanout_cursor='),
 retire:s=>s.startsWith('DELETE FROM n_group_member WHERE source=$1'),
 register:s=>s.startsWith('INSERT INTO devices('),
 sync:s=>s.startsWith('UPDATE feed_subscriptions s SET notifications_enabled=0')||s.startsWith('INSERT INTO feed_subscriptions('),
 readObject:s=>s.startsWith('SELECT sha256,bytes FROM n_snapshot'),
};
// Each side write's affected count is asserted on the owner's command tag
// before the held operation is forwarded; outside [min, max] nothing is, and
// the connection closes, so the Worker fails instead of passing vacuously.
const atLeastOne={min:1,max:Infinity},exactlyOne={min:1,max:1};
export const SIDE={
 stale_generation:{sql:'UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE dispatch_until>0',...atLeastOne},
 stale_epoch:{sql:'UPDATE n_feed SET epoch=epoch+1 WHERE dispatch_until>0',...atLeastOne},
 stale_settle:{sql:'UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE dispatch_until>0',...atLeastOne},
 stale_eligibility:{sql:'UPDATE n_feed SET eligibility_generation=eligibility_generation+1',...atLeastOne},
 stale_owner:{sql:'UPDATE n_feed SET epoch=epoch+1',...atLeastOne},
 lost_lease:{sql:"UPDATE n_feed SET lease_id='replacement' WHERE lease_id IS NOT NULL",...atLeastOne},
 final_send_off:{sql:"UPDATE n_control SET enabled=0 WHERE name='episode_send'",...exactlyOne},
 reclaim_fanout:{sql:"UPDATE n_event SET lease_id='reclaimed' WHERE fanout_complete=0",...atLeastOne},
};
// The fault names each entry's D1 hooks act on storage; every other name (R2,
// Queue, clock, abort, APNs, 'none') stays local to the entry. Cancellation's
// one storage hook is armed by its x-test-postscan header, not by a name.
export const PROXY_NAMES={
 polling:new Set(['d1','hang_claim','hang_bookkeeping','hang_redelivery_stat','origin_status_d1','before_publish','stale_generation','stale_epoch','before_settle','stale_settle','after_settle','after_publish']),
 observation:new Set(['watchdog_read_hang','watchdog_read','before_checkpoint','after_checkpoint','before_publish','publish_rollback','stale_eligibility','stale_owner','lost_lease','manifest_reserve']),
 delivery:new Set(['reclaim_fanout','fail_batch','final_send_off','fail_retire']),
 cancellation:new Set(),
};
export const isStorageHook=(entry,name)=>PROXY_NAMES[entry]?.has(String(name).replace(/^always:/,''))??false;
// The four instrumented test entries, by module path suffix.
export const ENTRIES=[['/FeedPollingWorker/tests/entry.mjs','polling'],['/NotificationsWorker/tests/observation-entry.mjs','observation'],['/NotificationsWorker/tests/delivery-entry.mjs','delivery'],['/NotificationsWorker/tests/cancellation-entry.mjs','cancellation']];
export function entryOf(worker){
 const paths=[...(Array.isArray(worker.modules)?worker.modules:[]).map(m=>typeof m==='string'?m:m?.path??''),worker.scriptPath??''].map(String);
 for(const [suffix,kind] of ENTRIES)if(paths.some(p=>p.endsWith(suffix)))return kind;
 return null;
}
export const ACTIONS=new Set(['close-before','fail-in-place','drop-commit-ack','side-write-first','hold-request','hold-forever','hold-response','fail-and-arm']);
export const HOLDS=new Set(['hold-request','hold-forever','hold-response']);

// What would fire on one complete operation, as the entry's D1 hook would,
// without effect. state: {entry, slot, auth, postscan} with slot = the active
// fault arming {name} (the entry's one `fault` variable), auth = the
// hold-auth-write arming {path}, postscan = the header-scoped arming. The
// result names the arming it consumes and how:
//   consume  the slot (or auth) arming is spent by this fire (one-shot);
//   followUp fail-and-arm's follow-up arming name, put in the slot;
//   active   the entry's fault-state value while this fire's hold is out;
//   release  which entry route releases it ('hang' | 'auth' | 'postscan').
export function match(state,op){
 const a=state.slot,f=a?.name,always=typeof f==='string'&&f.startsWith('always:'),name=always?f.slice(7):f;
 // A unit with no Parse (a prepared statement's Bind/Execute) has no SQL text.
 const app=op.statements,any=m=>app.some(m),sql=op.sql??'';
 // fail(point) in the D1 entries: one-shot unless armed always:.
 const fire=(hook,action,extra={})=>({arming:a,hook,action,consume:!always,...extra});
 const exact=(hook,action,extra={})=>({arming:a,hook,action,consume:true,...extra});
 if(state.entry==='polling'&&a){
  if(name==='d1'&&(op.type==='read'||app.length===1))return fire('P-d1','close-before');
  if(op.type==='read'&&M.claim(sql)){
   if(f==='hang_claim')return exact('P-hang_claim','hold-request',{active:'claim_active',release:'hang'});
   if(f==='hang_bookkeeping')return exact('P-hang_bookkeeping','fail-and-arm',{followUp:'bookkeeping_active'});
  }
  if(op.type==='txn'){
   // The follow-up stays armed until release-hang, as the entry's fault does.
   if(f==='bookkeeping_active'&&any(M.stat))return {arming:a,hook:'P-hang_bookkeeping',action:'hold-request',consume:false,follow_up:true,active:'bookkeeping_active',release:'hang'};
   if(f==='hang_redelivery_stat'&&any(M.redeliveryStat))return exact('P-hang_redelivery_stat','hold-request',{active:'redelivery_stat_active',release:'hang'});
   if(name==='origin_status_d1'&&any(M.origin))return fire('P-origin_status_d1','close-before');
   const publish=any(M.publish),settle=any(M.settle);
   if(publish&&name==='before_publish')return fire('P-before_publish','close-before');
   if(publish&&f==='stale_generation')return exact('P-stale_generation','side-write-first',{side:'stale_generation'});
   if(publish&&f==='stale_epoch')return exact('P-stale_epoch','side-write-first',{side:'stale_epoch'});
   if(settle&&name==='before_settle')return fire('P-before_settle','close-before');
   if(settle&&f==='stale_settle')return exact('P-stale_settle','side-write-first',{side:'stale_settle'});
   if(settle&&name==='after_settle')return fire('P-after_settle','drop-commit-ack');
   if(publish&&name==='after_publish')return fire('P-after_publish','drop-commit-ack');
  }
 }
 if(state.entry==='observation'&&a){
  if(op.type==='read'&&M.watchdog(sql)){
   if(f==='watchdog_read_hang')return exact('O-watchdog_read_hang','hold-forever');
   if(f==='watchdog_read')return exact('O-watchdog_read','close-before');
  }
  if(op.type==='txn'){
   if(any(M.checkpoint)&&f==='before_checkpoint')return exact('O-before_checkpoint','close-before');
   if(any(M.checkpoint)&&f==='after_checkpoint')return exact('O-after_checkpoint','drop-commit-ack');
   if(any(M.publish)){
    if(f==='before_publish')return exact('O-before_publish','close-before');
    if(f==='publish_rollback')return exact('O-publish_rollback','fail-in-place');
    for(const n of ['stale_eligibility','stale_owner','lost_lease'])if(f===n)return exact('O-'+n,'side-write-first',{side:n});
   }
   if(any(M.manifest)&&f==='manifest_reserve')return exact('O-manifest_reserve','close-before');
  }
 }
 if(state.entry==='delivery'){
  if(a){
   if(op.type==='read'&&M.sendAuthority(sql)&&f==='final_send_off')return exact('D-final_send_off','side-write-first',{side:'final_send_off'});
   if(op.type==='txn'&&any(M.fanout)){
    if(f==='reclaim_fanout')return exact('D-reclaim_fanout','side-write-first',{side:'reclaim_fanout'});
    if(f==='fail_batch')return exact('D-fail_batch','fail-in-place');
   }
   if(op.type==='txn'&&any(M.retire)&&f==='fail_retire')return exact('D-fail_retire','fail-in-place');
  }
  const h=state.auth;
  if(h&&op.type==='txn'&&((h.path==='/v1/devices/register'&&M.register(app[0]??''))||(h.path==='/v1/subscriptions/sync'&&any(M.sync))))
   return {arming:h,hook:'D-hold_auth_write',action:'hold-request',consume:true,release:'auth'};
 }
 if(state.entry==='cancellation'&&state.postscan&&op.type==='read'&&M.readObject(sql))
  return {arming:state.postscan,hook:'C-postscan',action:'hold-response',consume:false,release:'postscan'};
 return null;
}
