// D1 rows read by the two statements that dominated production reads
// (2026-10-08 plan): the cleanup cron's observation retention DELETE and the
// per-minute dispatcher rollup. Exact deleted sets, bounded rows read.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness,item,rss } from './harness.mjs';
const failures=[];
// Every check runs and prints its number, so one red bound cannot hide another.
const check=(name,fn)=>{try{fn();console.log(`PASS ${name}`);}catch(error){failures.push(name);console.log(`FAIL ${name}: ${error.message}`);}};
const insert=(db,table,row)=>{const columns=Object.keys(row);return db.prepare(`INSERT INTO ${table}(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`).bind(...columns.map(k=>row[k]));};
const batches=async(db,statements)=>{for(let i=0;i<statements.length;i+=100)await db.batch(statements.slice(i,i+100));};

// 1. Cleanup cron: ~300 permanent candidates (each feed's current published
// observation older than seven days) against ~400 feeds.
{
  const h=await harness(()=>new Response(rss([item('base',h.now-100)])));
  try {
    const feed=await h.add('https://rows-read.example.com/feed');
    await h.invoke('test/dispatch');await h.drain();
    const template=await h.first('SELECT * FROM n_observation WHERE feed_id=?',feed);
    const snapshot=await h.first('SELECT * FROM n_snapshot WHERE object_key=?',template.snapshot_key);
    assert.ok(template&&snapshot,'the real poll published an observation and its manifest');
    const feeds=[];
    for(let i=0;i<400;i++)feeds.push(await h.add(`https://rows-read-${i%20}.example.com/${i}`,h.now+90000));
    await h.run('UPDATE n_feed SET due_at=?',h.now+90000);
    const old=h.now-8*86400,statements=[];
    // A cloned observation with its own manifest row on `feed_id`.
    const observation=(feed_id,fields={})=>{
      const row={...template,observation_id:randomUUID(),feed_id,lease_id:randomUUID(),snapshot_key:randomUUID(),scan_started_at:old,completed_at:old,state:'published',drain_complete:1,...fields};
      if(!fields.snapshot_key)statements.push(insert(h.db,'n_snapshot',{...snapshot,object_key:row.snapshot_key,feed_id}));
      statements.push(insert(h.db,'n_observation',row));return row;
    };
    const permanent=feeds.slice(0,300).map(id=>{const row=observation(id);statements.push(h.db.prepare('UPDATE n_feed SET snapshot_key=? WHERE feed_id=?').bind(row.snapshot_key,id));return row;});
    const leased=randomUUID(),lapsed=randomUUID();
    statements.push(h.db.prepare('UPDATE n_feed SET lease_id=?,lease_until=? WHERE feed_id=?').bind(leased,h.now+3600,feeds[300]));
    statements.push(h.db.prepare('UPDATE n_feed SET lease_id=?,lease_until=? WHERE feed_id=?').bind(lapsed,h.now-10,feeds[301]));
    const deletable={
      unreferenced:observation(feeds[302]),
      not_published:observation(feeds[303],{state:'abandoned',drain_complete:0,recovery_evidence:0}),
      lapsed_lease:observation(feeds[301],{lease_id:lapsed}),
    };
    const retained={
      other_feeds_snapshot:observation(feeds[304],{snapshot_key:permanent[0].snapshot_key}),
      live_lease:observation(feeds[300],{lease_id:leased}),
      episode_release:observation(feeds[305]),
      outbox:observation(feeds[306]),
      undrained:observation(feeds[307],{drain_complete:0}),
      too_young:observation(feeds[308],{scan_started_at:h.now-6*86400}),
    };
    statements.push(insert(h.db,'n_episode_release',{feed_id:feeds[305],episode_id:'rows-read-release',observation_id:retained.episode_release.observation_id,generation:1,owner_epoch:1,event_id:randomUUID(),presentation_key:randomUUID(),first_observed_at:old,eligible_at:old,expires_at:h.now+86400,reason:'fixture',metadata_json:'{}',state:'outboxed'}));
    statements.push(insert(h.db,'n_outbox',{source:'feed_polling',event_id:randomUUID(),observation_id:retained.outbox.observation_id,payload_digest:'fixture',occurred_at:old,expires_at:h.now+86400,next_attempt_at:h.now,state:'accepted'}));
    await batches(h.db,statements);
    const ids=async()=>new Set((await h.rows('SELECT observation_id FROM n_observation')).map(r=>r.observation_id));
    const before=await ids(),metricsBefore=await h.invoke('metrics');
    const response=await h.instance.dispatchFetch('http://localhost/cdn-cgi/local/scheduled?cron='+encodeURIComponent('*/2 * * * *'));
    assert.equal(response.status,200,await response.text());
    const metricsAfter=await h.invoke('metrics'),after=await ids();
    assert.equal(metricsAfter.cleanup.length,metricsBefore.cleanup.length+1,'one cleanup invocation ran');
    const deleted=[...before].filter(id=>!after.has(id)),rowsRead=metricsAfter.rows_read-metricsBefore.rows_read;
    console.log(`cleanup cron: ${(await h.first('SELECT COUNT(*) AS n FROM n_feed')).n} feeds, ${before.size} observations, deleted ${deleted.length}, rows_read ${rowsRead}, d1 ${metricsAfter.d1-metricsBefore.d1}`);
    check('cleanup cron deletes exactly the deletable observations',()=>assert.deepEqual(deleted.sort(),Object.values(deletable).map(r=>r.observation_id).sort()));
    check(`cleanup cron reads under 20000 rows (${rowsRead})`,()=>assert.ok(rowsRead<20000,`rows_read ${rowsRead}`));
  } finally {await h.instance.dispose();}
}

// 2. Dispatcher rollup: 300 eligible feeds, none due, no origin cooldowns.
{
  const h=await harness(()=>new Response(rss([item('base',h.now-100)])));
  try {
    const FEEDS=300;
    for(let i=0;i<FEEDS;i++)await h.add(`https://rollup-${i%20}.example.com/${i}`,h.now+3600);
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE no_interest_since IS NULL')).n,FEEDS,'every feed has an enabled interest');
    const before=await h.invoke('metrics');
    await h.invoke('test/dispatch');
    const after=await h.invoke('metrics'),tick=after.recent.filter(t=>t.path==='/test/dispatch').at(-1);
    console.log(`dispatch tick: ${FEEDS} feeds, rollup_rows_read ${tick.rollup_rows_read}, tick rows_read ${after.rows_read-before.rows_read}, d1 ${after.d1-before.d1}`);
    check('the rollup statement was captured',()=>assert.ok(tick.rollup_rows_read>0,'no statement carried AS completed_last_5min'));
    check(`rollup reads under ${6*FEEDS} rows (${tick.rollup_rows_read})`,()=>assert.ok(tick.rollup_rows_read<6*FEEDS,`rollup_rows_read ${tick.rollup_rows_read}`));
  } finally {await h.instance.dispose();}
}
assert.deepEqual(failures,[],`rows-read failures: ${failures.join('; ')}`);
