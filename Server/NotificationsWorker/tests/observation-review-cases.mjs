import assert from 'node:assert/strict';

// Regressions from the independent observation review. These run inside the actual
// packaged-worker fixture and report all findings even against the old bundle.
export async function reviewRegressions(h) {
  const {mf,now,item,hash,newFeed,command,drain,run,first,queue,subscribe,feed,clock,setClock,content}=h;
  const results={},failures=[];
  const raw=path=>mf.dispatchFetch('https://runtime.example.com/observation/'+path,{method:'POST',body:JSON.stringify({feed_id:feed()})});
  async function check(name,body){
    try{results[name]=await body();console.log('PASS review',name);}
    catch(error){failures.push(new Error(name,{cause:error}));console.error('FAIL review',name,error);}
  }
  async function failedScan(name){
    await newFeed(name);
    content(name+'-broken',[item('partial',null)],'<item><title>unfinished');
    const response=await raw('scan');assert.equal(response.status,500);await response.text();
    return (await first("SELECT MIN(scan_started_at) AS at FROM n_observation WHERE feed_id=? AND recovery_evidence=1",feed())).at;
  }
  async function stagedScan(name){
    await newFeed(name);
    content(name+'-new',[item('pending',null)]);
    const response=await raw('scan');assert.equal(response.status,200);await response.text();
    return first("SELECT * FROM n_observation WHERE feed_id=? AND state='staging' AND valid_eof=1",feed());
  }
  await check('M1 dated outage recovery',async()=>{
    const bound=await failedScan('review-date-outage');
    await setClock(clock()+2*86400);
    const scanTime=now+clock(), futureDate=scanTime+6*86400;
    content('review-recovered',[...Array.from({length:5},(_,i)=>item('dated-'+i,scanTime-(i+1)*3600)),item('scheduled',futureDate)]);
    await command('scan');await drain();
    const releases=(await (await mf.getD1Database('APP_ATTEST_DB')).prepare('SELECT * FROM n_episode_release WHERE feed_id=?').bind(feed()).all()).results;
    const recent=releases.filter(r=>r.reason==='recent');
    assert.equal(recent.length,5);assert.equal(new Set(recent.map(r=>r.presentation_key)).size,1);
    for(const r of recent){assert.equal(r.first_observed_at,bound);assert.equal(r.eligible_at,r.published_at);assert.equal(r.expires_at,r.published_at+86400);}
    const future=releases.find(r=>r.reason==='future');assert.ok(future);
    assert.equal(future.state,'pending_future');assert.equal(future.eligible_at,futureDate);assert.equal(future.expires_at,futureDate+86400);
    await command('outbox');await queue('event',recent[0].event_id);await queue('event',recent[0].event_id);
    const delivery=await first('SELECT member_count FROM n_delivery WHERE interest_key=?',feed());assert.equal(delivery.member_count,5);
    return {recent:recent.length,pendingFuture:1,memberCount:delivery.member_count};
  });
  await check('L1 subscription after failed scan',async()=>{
    const bound=await failedScan('review-interest-outage');
    await setClock(clock()+2*86400);
    await subscribe('review-new-subscriber',bound+3600);
    content('review-interest-recovered',[item('dated-after-subscription',now+clock()-3600),item('ambiguous-undated',null)]);
    await command('scan');await drain();await command('outbox');
    const release=await first("SELECT * FROM n_episode_release WHERE feed_id=? AND published_at IS NOT NULL",feed());
    for(let i=0;i<3;i++)await queue('event',release.event_id);
    assert.equal((await first("SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=? AND install_id='review-new-subscriber'",feed())).n,1);
    // The older per-event path must apply the same dated cutoff. This envelope
    // has valid published observation authority but no grouped release record.
    const source=await first('SELECT payload_json FROM n_outbox WHERE event_id=?',release.event_id);
    const event=JSON.parse(source.payload_json);
    event.routing.episode_id='review-fallback';event.event_id=hash(['episode-v1','development',feed(),event.routing.episode_id]);
    const accepted=await mf.dispatchFetch('https://runtime.example.com/v1/events',{method:'POST',body:JSON.stringify(event)});
    const receipt=await accepted.json();assert.equal(accepted.status,200);assert.equal(receipt.disposition,'accepted');await queue('event',event.event_id);
    assert.equal((await first("SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=? AND install_id='review-new-subscriber'",event.event_id)).n,1);
    return {groupedPathDeliveries:1,fallbackPathDeliveries:1};
  });
  await check('M2 reservation and 304 retention',async()=>{
    await newFeed('review-reservations');
    const reserved=async()=> (await first("SELECT COUNT(*) AS n FROM n_snapshot WHERE feed_id=? AND state='reserved'",feed())).n;
    const baselineReserved=await reserved();assert.equal(baselineReserved,0);
    content('review-rescan',[item('baseline'),item('one-new',null)]);await command('scan');await drain();
    const rescanReserved=await reserved();assert.equal(rescanReserved,0);
    const counts=()=>first('SELECT (SELECT COUNT(*) FROM n_snapshot WHERE feed_id=?1) AS snapshots,(SELECT COUNT(*) FROM n_observation WHERE feed_id=?1) AS observations',feed());
    const before=await counts();for(let i=0;i<5;i++)await command('scan');const after=await counts();assert.deepEqual(after,before);
    const abandoned=(await first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='abandoned'",feed())).n;assert.equal(abandoned,0);
    return {baselineReserved,rescanReserved,abandoned,matched304SnapshotDelta:after.snapshots-before.snapshots,matched304ObservationDelta:after.observations-before.observations};
  });
  await check('M3 poisoned preparation recovery',async()=>{
    const staged=await stagedScan('review-poisoned');
    const retained=await first("SELECT object_key FROM n_snapshot WHERE lease_id=? AND state='uploaded' AND gc_after=created_at+86400 LIMIT 1",staged.lease_id);assert.ok(retained);
    await run('UPDATE n_observation SET processing_failures=10 WHERE observation_id=?',staged.observation_id);
    await command('prepare');
    const poisoned=await first('SELECT state,recovery_evidence,reason_counts_json FROM n_observation WHERE observation_id=?',staged.observation_id);
    assert.equal(poisoned.state,'abandoned');assert.equal(poisoned.recovery_evidence,1);assert.equal(JSON.parse(poisoned.reason_counts_json).preparation_poisoned,1);
    await setClock(clock()+2*86400);await command('gc');
    const bucket=await mf.getR2Bucket('FEED_SNAPSHOTS');assert.ok(await bucket.head(retained.object_key),'abandoned recovery pages retain their grace');
    await command('scan');await drain();
    assert.equal((await first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed())).observation_generation,2);
    assert.equal((await first('SELECT first_observed_at FROM n_episode_release WHERE feed_id=?',feed())).first_observed_at,staged.scan_started_at);
    // Exercise the actual tenth-error transition as well as existing poison.
    const tenth=await stagedScan('review-tenth-error');
    await run('UPDATE n_observation SET processing_failures=9 WHERE observation_id=?',tenth.observation_id);
    await mf.dispatchFetch('https://runtime.example.com/fault',{method:'POST',body:'before_put'});
    const failed=await raw('prepare');assert.equal(failed.status,500);await failed.text();
    const row=await first('SELECT state,processing_failures FROM n_observation WHERE observation_id=?',tenth.observation_id);assert.deepEqual(row,{state:'abandoned',processing_failures:10});
    await command('scan');await drain();
    assert.equal((await first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed())).observation_generation,2);
    return {abandoned:2,recovered:2};
  });
  if(failures.length)throw new AggregateError(failures,'observation review regressions');
  return results;
}
