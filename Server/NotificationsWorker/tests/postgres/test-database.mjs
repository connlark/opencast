// pg.mjs's wire client and database.mjs's D1-shaped handle.
// Pure: RFC 7677's SCRAM-SHA-256 vector and the parse/verify refusals.
// Fake servers on loopback: every SCRAM refusal rule, the startup parameters,
// Terminate with the server closing first, and the bounded close fallback.
// Live, against the local topology (Server/NotificationsWorker/postgres/local/
// local-postgres.sh status exits 0): SCRAM over TCP, 28P01, the search_path
// startup parameter, and the handle on a fresh clone of opencast_template that
// this test creates and drops itself as postgres.
// Run: node Server/NotificationsWorker/tests/postgres/test-database.mjs
// (OPENCAST_PG_HOST / OPENCAST_PG_PORT override 127.0.0.1:55432).
import assert from 'node:assert/strict';
import net from 'node:net';
import {createHash,createHmac,pbkdf2Sync,randomBytes} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {Client,GATE,AuthenticationRefused,PostgresError,CLOSE_FALLBACK_MS,scramClientFirst,scramClientFinal,parseServerFirst,verifyServerFinal} from './pg.mjs';
import {Database,D1OnlyMetaField} from './database.mjs';
import {D1PhysicalStatement,UnmappedStatement} from './sql.mjs';
const host=process.env.OPENCAST_PG_HOST??'127.0.0.1',port=Number(process.env.OPENCAST_PG_PORT??55432);
// The local topology's fixed fixture passwords (local-postgres.sh).
const POSTGRES='opencast-local-postgres',OWNER='opencast_local_owner',OWNER_PASSWORD='opencast-local-owner';
const run=randomBytes(6).toString('hex');
let failed=0;
async function test(name,fn,ms=30000){
 let timer;
 try{await Promise.race([fn(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(`timed out after ${ms} ms`)),ms);})]);console.log('ok',name);}
 catch(error){failed++;console.log('not ok',name);console.log(error);}
 finally{clearTimeout(timer);}
}
const refused=(reason)=>error=>{assert.ok(error instanceof AuthenticationRefused,String(error));assert.match(error.reason,reason);return true;};

// ---- Pure: RFC 7677 section 3, user "user", password "pencil".
await test('SCRAM-SHA-256 reproduces the RFC 7677 vector and verifies its server signature',async()=>{
 const first=scramClientFirst({nonce:'rOprNGfwEbeRWgbNEkqO',user:'user'});
 assert.equal(first.message,'n,,n=user,r=rOprNGfwEbeRWgbNEkqO');
 const serverFirst='r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096';
 const final=await scramClientFinal({password:'pencil',clientNonce:first.nonce,clientFirstBare:first.bare,serverFirst});
 assert.equal(final.message,'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=');
 assert.equal(final.serverSignature.toString('base64'),'6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=');
 verifyServerFinal('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=',final.serverSignature);
 assert.throws(()=>verifyServerFinal('v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=',final.serverSignature),refused(/signature mismatch/));
});
await test('SCRAM parse and verify refuse every malformed or foreign message',async()=>{
 const c='clientnonce';
 for(const [text,reason] of [['r=Xlientnonce123,s=c2FsdA==,i=4096',/does not extend/],['r=clientnonce,s=c2FsdA==,i=4096',/does not extend/],
  ['r=clientnonce123,i=4096',/malformed server-first/],['m=ext,r=clientnonce123,s=c2FsdA==,i=4096',/malformed server-first/],
  ['r=clientnonce123,s=c2FsdA==,i=4096,x=1',/malformed server-first/],['r=clientnonce123,s=*,i=4096',/malformed salt/],
  ['r=clientnonce123,s=c2FsdA==,i=0',/iteration count/],['r=clientnonce123,s=c2FsdA==,i=04096',/iteration count/],['r=client nonce1,s=c2FsdA==,i=1',/server nonce/]])
  assert.throws(()=>parseServerFirst(text,c),refused(reason),text);
 const signature=Buffer.alloc(32,7);
 for(const [text,reason] of [['e=invalid-proof',/server-final error invalid-proof/],['v=***',/malformed server-final/],['',/malformed server-final/],
  [`v=${signature.toString('base64')},x=1`,/malformed server-final/],[`v=${Buffer.alloc(31,7).toString('base64')}`,/signature mismatch/]])
  assert.throws(()=>verifyServerFinal(text,signature),refused(reason),text);
 verifyServerFinal(`v=${signature.toString('base64')}`,signature);
 await assert.rejects(scramClientFinal({password:'pässword',clientNonce:c,clientFirstBare:'n=,r='+c,serverFirst:'r=clientnonce1,s=c2FsdA==,i=1'}),TypeError);
});

// ---- Fake servers: a scripted PostgreSQL that runs real SCRAM server
// arithmetic, then breaks exactly one rule per mode.
const FAKE_PASSWORD='fake-scram-password';
const hmac=(k,t)=>createHmac('sha256',k).update(t).digest(),sha256=b=>createHash('sha256').update(b).digest();
const be32=n=>{const b=Buffer.alloc(4);b.writeInt32BE(n);return b;};
const msg=(kind,body=Buffer.alloc(0))=>Buffer.concat([Buffer.from(kind),be32(body.length+4),Buffer.from(body)]);
const authMsg=(code,data='')=>msg('R',Buffer.concat([be32(code),Buffer.from(data)]));
const READY=Buffer.concat([authMsg(0),msg('S','server_version\x0017.0\x00'),msg('K',Buffer.concat([be32(1),be32(2)])),msg('Z','I')]);
function frames(socket){
 let buffer=Buffer.alloc(0),started=false,waiting=null;const ready=[];
 const pump=()=>{
  for(;;){
   if(!started){if(buffer.length<4||buffer.length<buffer.readInt32BE(0))break;const n=buffer.readInt32BE(0);ready.push({kind:'startup',body:buffer.subarray(8,n)});buffer=buffer.subarray(n);started=true;continue;}
   if(buffer.length<5||buffer.length<buffer.readInt32BE(1)+1)break;const n=buffer.readInt32BE(1);
   ready.push({kind:String.fromCharCode(buffer[0]),body:buffer.subarray(5,n+1)});buffer=buffer.subarray(n+1);
  }
  if(waiting&&ready.length){const w=waiting;waiting=null;w(ready.shift());}
 };
 socket.on('data',chunk=>{buffer=Buffer.concat([buffer,chunk]);pump();});
 socket.on('close',()=>{if(waiting){const w=waiting;waiting=null;w(null);}});
 return ()=>new Promise(resolve=>{if(ready.length)resolve(ready.shift());else waiting=resolve;});
}
async function serve(socket,mode,record){
 let order=0;
 socket.on('end',()=>{record.clientFin=++order;});socket.on('error',()=>{});
 const next=frames(socket),send=b=>socket.write(b);
 const startup=await next();if(!startup)return;
 const parts=startup.body.toString().split('\0');record.params={};for(let i=0;i+1<parts.length&&parts[i];i+=2)record.params[parts[i]]=parts[i+1];
 // On Terminate the server waits 200 ms before closing: a client that ends
 // first is seen ending first.
 const tail=async()=>{for(;;){const m=await next();if(!m)return;record.kinds.push(m.kind);if(m.kind==='X'&&mode!=='ignore-terminate')setTimeout(()=>{record.serverFin=++order;socket.end();},200);}};
 if(mode==='cleartext')return send(authMsg(3)),tail();
 if(mode==='md5')return send(authMsg(5,randomBytes(4))),tail();
 if(mode==='trust')return send(READY),tail();
 send(authMsg(10,(mode==='plus-only'?'SCRAM-SHA-256-PLUS':'SCRAM-SHA-256-PLUS\0SCRAM-SHA-256')+'\0\0'));
 const initial=await next();if(!initial)return;record.kinds.push(initial.kind);
 const z=initial.body.indexOf(0);record.mechanism=initial.body.subarray(0,z).toString();
 const clientFirst=initial.body.subarray(z+5,z+5+initial.body.readInt32BE(z+1)).toString();record.clientFirst=clientFirst;
 const bare=clientFirst.slice(3),cnonce=/(?:^|,)r=([^,]*)/.exec(bare)[1];
 // A first character that differs from the client's, never a fixed 'X': a
 // random base64 nonce starts with 'X' one time in 64.
 const snonce=mode==='nonce-prefix'?(cnonce[0]==='X'?'Y':'X')+cnonce.slice(1)+'server':mode==='nonce-equal'?cnonce:cnonce+randomBytes(12).toString('base64');
 const salt=randomBytes(16),iterations=4096;
 let serverFirst=`r=${snonce},s=${salt.toString('base64')},i=${iterations}`;
 if(mode==='malformed-first')serverFirst=`r=${snonce},i=${iterations}`;
 if(mode==='mandatory-extension')serverFirst=`m=ext,${serverFirst}`;
 send(authMsg(11,serverFirst));
 const response=await next();if(!response)return;record.kinds.push(response.kind);
 const clientFinal=response.body.toString(),at=clientFinal.lastIndexOf(',p=');
 const withoutProof=clientFinal.slice(0,at),proof=Buffer.from(clientFinal.slice(at+3),'base64');
 const salted=pbkdf2Sync(FAKE_PASSWORD,salt,iterations,32,'sha256'),authMessage=`${bare},${serverFirst},${withoutProof}`;
 const storedKey=sha256(hmac(salted,'Client Key')),clientSignature=hmac(storedKey,authMessage);
 record.proofValid=proof.length===32&&sha256(Buffer.from(proof.map((b,k)=>b^clientSignature[k]))).equals(storedKey);
 record.channelBinding=withoutProof.startsWith('c=biws,');
 if(!record.proofValid){send(msg('E','SFATAL\0C28P01\0Mpassword authentication failed\0\0'));record.serverFin=++order;socket.end();return;}
 const signature=hmac(hmac(salted,'Server Key'),authMessage);
 if(mode==='bad-signature')signature[0]^=1;
 const final={'error-final':'e=invalid-proof','malformed-final':`v=${signature.toString('base64')},x=1`,'bad-base64-final':'v=***'}[mode]??`v=${signature.toString('base64')}`;
 send(mode==='skip-final'?READY:Buffer.concat([authMsg(12,final),READY]));
 return tail();
}
async function fake(mode){
 const connections=[];
 const server=net.createServer(socket=>{const record={kinds:[]};connections.push(record);serve(socket,mode,record);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 return {port:server.address().port,connections,close:()=>{server.close();server.unref();}};
}
const fakeOptions=(server,extra={})=>({host:'127.0.0.1',port:server.port,user:'fixture_user',database:'fixture_db',password:FAKE_PASSWORD,...extra});

await test('fake server: SCRAM succeeds with n,, and a fresh nonce; startup parameters; Terminate, server closes first',async()=>{
 const server=await fake('ok');
 try{
  const a=await Client.connect(fakeOptions(server,{application:'fake-app',searchPath:'opencast, pg_catalog'}));
  assert.equal(a.mechanism,'SCRAM-SHA-256');assert.equal(a.status,'I');
  const [ra]=server.connections;
  assert.deepEqual(ra.params,{user:'fixture_user',database:'fixture_db',application_name:'fake-app',search_path:'opencast, pg_catalog'});
  assert.equal(ra.mechanism,'SCRAM-SHA-256');assert.match(ra.clientFirst,/^n,,n=,r=[A-Za-z0-9+/]{24}$/);
  assert.equal(ra.proofValid,true);assert.equal(ra.channelBinding,true);
  const closing=Date.now();await a.close();
  assert.ok(Date.now()-closing>=150,'close() waited for the server');
  assert.equal(a.closedBy,'server');assert.deepEqual(ra.kinds,['p','p','X']);
  // The server side sees the client's FIN on a later turn of the shared loop.
  for(let i=0;i<50&&ra.clientFin===undefined;i++)await sleep(10);
  assert.ok(ra.serverFin<ra.clientFin,`server FIN ${ra.serverFin} before client FIN ${ra.clientFin}`);
  const b=await Client.connect(fakeOptions(server));await b.close();
  const rb=server.connections[1];
  assert.equal('search_path' in rb.params,false);assert.equal(rb.params.application_name,'opencast-test');
  assert.notEqual(rb.clientFirst,ra.clientFirst,'every connection draws a fresh client nonce');
 }finally{server.close();}
});
await test('fake server: a wrong password is the server\'s 28P01',async()=>{
 const server=await fake('ok');
 try{await assert.rejects(Client.connect(fakeOptions(server,{password:'not-the-password'})),error=>error instanceof PostgresError&&error.code==='28P01');}
 finally{server.close();}
});
await test('fake server: every SCRAM rule and every foreign authentication request refuses the connection',async()=>{
 // [mode, reason, frontend messages the server may have seen]
 const cases=[['bad-signature',/server signature mismatch/,['p','p']],['nonce-prefix',/does not extend the client nonce/,['p']],
  ['nonce-equal',/does not extend the client nonce/,['p']],['error-final',/server-final error invalid-proof/,['p','p']],
  ['malformed-first',/malformed server-first/,['p']],['mandatory-extension',/malformed server-first/,['p']],
  ['malformed-final',/malformed server-final/,['p','p']],['bad-base64-final',/malformed server-final/,['p','p']],
  ['skip-final',/request 0 \(Ok\) where 12/,['p','p']],['plus-only',/no SCRAM-SHA-256 among SCRAM-SHA-256-PLUS/,[]],
  ['cleartext',/request 3 \(CleartextPassword\)/,[]],['md5',/request 5 \(MD5Password\)/,[]],['trust',/skipped authentication/,[]]];
 for(const [mode,reason,kinds] of cases){
  const server=await fake(mode);
  try{
   await assert.rejects(Client.connect(fakeOptions(server)),refused(reason),mode);
   await sleep(20);
   // No proof after a bad server-first, no password at all on cleartext/MD5/trust,
   // and nothing after a refusal: the client destroyed the connection.
   assert.deepEqual(server.connections[0].kinds,kinds,mode);
  }finally{server.close();}
 }
});
await test('fake server: trust is accepted only for a connection opened without a password',async()=>{
 const server=await fake('trust');
 try{const c=await Client.connect(fakeOptions(server,{password:undefined}));assert.equal(c.mechanism,'trust');await c.close();assert.equal(c.closedBy,'server');}
 finally{server.close();}
 const sasl=await fake('ok');
 try{await assert.rejects(Client.connect(fakeOptions(sasl,{password:undefined})),refused(/no password was given/));}
 finally{sasl.close();}
});
await test('fake server: a server that ignores Terminate is destroyed after the bounded fallback',async()=>{
 const server=await fake('ignore-terminate');
 try{
  const c=await Client.connect(fakeOptions(server));const started=Date.now();await c.close();const elapsed=Date.now()-started;
  assert.equal(c.closedBy,'fallback');assert.ok(elapsed>=CLOSE_FALLBACK_MS-50&&elapsed<CLOSE_FALLBACK_MS+1000,`${elapsed} ms`);
  assert.deepEqual(server.connections[0].kinds,['p','p','X']);
 }finally{server.close();}
});

// ---- Live: the local topology.
const name=`opencast_t_dbtest_${run}`,application=`opencast-test-database-${run}`;
const owner=(extra={})=>Client.connect({host,port,user:OWNER,password:OWNER_PASSWORD,database:name,application,...extra});
let admin=null,created=false;
try{admin=await Client.connect({host,port,user:'postgres',password:POSTGRES,database:'postgres',application:`${application}-admin`});}
catch(error){failed++;console.log(`not ok live topology at ${host}:${port}: ${error.message} (is Server/NotificationsWorker/postgres/local/local-postgres.sh status 0?)`);}
const clients=[];let db=null;
if(admin)try{
 await test('live: clone opencast_template as postgres, owned by the owner role',async()=>{
  await admin.simple(`CREATE DATABASE ${name} TEMPLATE opencast_template OWNER ${OWNER}`);created=true;
  assert.deepEqual((await admin.query('SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname=$1',[name])).rows,[{owner:OWNER}]);
 });
 await test('live: the owner authenticates by SCRAM-SHA-256 over TCP and closes server-first',async()=>{
  const c=await owner();clients.push(c);
  assert.equal(c.mechanism,'SCRAM-SHA-256');
  const [row]=(await c.query('SELECT system_user AS method,inet_client_addr() IS NOT NULL AS tcp,current_user AS who')).rows;
  assert.deepEqual(row,{method:`scram-sha-256:${OWNER}`,tcp:1,who:OWNER});
  await c.close();assert.equal(c.closedBy,'server');
 });
 await test('live: a wrong password fails with 28P01',async()=>{
  await assert.rejects(owner({password:'opencast-local-wrong'}),error=>error instanceof PostgresError&&error.code==='28P01');
 });
 await test('live: SHOW search_path honours the startup parameter',async()=>{
  for(const [searchPath,expected] of [[undefined,'opencast, pg_catalog'],['pg_catalog','pg_catalog'],['opencast','opencast']]){
   const c=await owner({searchPath});clients.push(c);
   assert.deepEqual((await c.query('SHOW search_path')).rows,[{search_path:expected}],String(searchPath));
   await c.close();
  }
 });
 await test('live: the record\'s typing on the clone; an unsafe int8 throws and the connection stays usable',async()=>{
  const c=await owner();clients.push(c);
  const r=await c.query("SELECT 1::int2 AS i2,2::int4 AS i4,9007199254740991::int8 AS i8,12.5::numeric AS n,3::numeric AS ni,true AS t,false AS f,'\\x00ff'::bytea AS b,NULL::int8 AS z,1.5::float8 AS d,'x'::text AS s");
  assert.deepEqual(r.rows,[{i2:1,i4:2,i8:9007199254740991,n:12.5,ni:3,t:1,f:0,b:new Uint8Array([0,255]),z:null,d:1.5,s:'x'}]);
  await assert.rejects(c.query('SELECT 9007199254740993::int8 AS u'),/unsafe numeric 9007199254740993/);
  await assert.rejects(c.query('SELECT (-9007199254740993)::int8 AS u'),/unsafe numeric/);
  assert.equal(c.status,'I');assert.deepEqual((await c.query('SELECT 1::int8 AS one')).rows,[{one:1}]);
  await c.close();
 });
 db=new Database({host,port,database:name,user:OWNER,password:OWNER_PASSWORD,application});
 const count=async names=>(await db.prepare(`SELECT COUNT(*) AS n FROM n_control WHERE name IN(${names.map(()=>'?').join(',')})`).bind(...names).first('n'));
 await test('live handle: typed binds and reads (int8, bytea, bool, NULL, float8 for an unsafe number)',async()=>{
  await db.prepare('INSERT INTO app_attest_keys(install_id,key_id,public_key,sign_counter,app_id,environment,created_at,last_used_at) VALUES(?,?,?,?,?,?,?,?)')
   .bind('install-t','key-t',new Uint8Array([0,1,254,255]),2**53-1,'app','development',1,2).run();
  const key=await db.prepare('SELECT public_key,sign_counter,(sign_counter>0) AS positive FROM app_attest_keys WHERE install_id=? AND key_id=?').bind('install-t','key-t').first();
  assert.deepEqual(key,{public_key:new Uint8Array([0,1,254,255]),sign_counter:2**53-1,positive:1});
  await db.prepare('INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?,?,?,?)').bind('https://t.example/feed','https://t.example/feed',1,1).run();
  assert.equal(await db.prepare('SELECT title FROM n_feed_catalog WHERE feed_url=?').bind('https://t.example/feed').first('title'),null);
  await db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,?,?)').bind('typing-bool',true,1).run();
  assert.equal(await db.prepare('SELECT enabled FROM n_control WHERE name=?').bind('typing-bool').first('enabled'),1);
  // 2**53+2 is not a safe integer: it binds as float8, lands in a BIGINT and reads back unsafe.
  await db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,?)').bind('typing-unsafe',2**53+2).run();
  await assert.rejects(db.prepare('SELECT revision FROM n_control WHERE name=?').bind('typing-unsafe').first('revision'),/unsafe numeric 9007199254740994/);
  assert.throws(()=>db.prepare('SELECT 1 FROM n_control WHERE name=?').bind(undefined),/D1_TYPE_ERROR: Type 'undefined'/);
  assert.throws(()=>db.prepare('SELECT 1 FROM n_control WHERE name=?').bind({}),/D1_TYPE_ERROR: Type 'object'/);
 });
 await test('live handle: first(column) and raw({columnNames})',async()=>{
  const read=db.prepare('SELECT name,enabled,name FROM n_control WHERE name=?');
  assert.equal(await db.prepare('SELECT enabled FROM n_control WHERE name=?').bind('typing-bool').first('enabled'),1);
  assert.deepEqual(await db.prepare('SELECT name,revision FROM n_control WHERE name=?').bind('typing-bool').first(),{name:'typing-bool',revision:1});
  await assert.rejects(db.prepare('SELECT name FROM n_control WHERE name=?').bind('typing-bool').first('missing'),/D1_COLUMN_NOTFOUND: Column not found \(missing\)/);
  assert.equal(await db.prepare('SELECT name FROM n_control WHERE name=?').bind('absent').first('missing'),null);
  assert.equal(await db.prepare('SELECT name FROM n_control WHERE name=?').bind('absent').first(),null);
  assert.deepEqual(await read.bind('typing-bool').raw({columnNames:true}),[['name','enabled','name'],['typing-bool',1,'typing-bool']]);
  assert.deepEqual(await read.bind('typing-bool').raw(),[['typing-bool',1,'typing-bool']]);
  assert.deepEqual(await read.bind('absent').raw({columnNames:true}),[['name','enabled','name']]);
 });
 await test('live handle: a gated batch commits; while the gate is held a read runs and a write or batch waits on the lock',async()=>{
  const results=await db.batch([
   db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,1)').bind('batch-a'),
   db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,1,2)').bind('batch-b'),
   db.prepare("SELECT COUNT(*) AS n FROM n_control WHERE name LIKE 'batch-%'"),
  ]);
  assert.deepEqual(results.map(r=>[r.success,r.meta.changes,r.results]),[[true,1,[]],[true,1,[]],[true,0,[{n:2}]]]);
  const other=await owner({application:`${application}-reader`});clients.push(other);
  assert.deepEqual((await other.query("SELECT name FROM n_control WHERE name LIKE 'batch-%' ORDER BY name")).rows,[{name:'batch-a'},{name:'batch-b'}]);
  const holder=await owner({application:`${application}-gate`});clients.push(holder);
  await holder.query('BEGIN');await holder.query(GATE);
  try{
   assert.equal(await count(['batch-a','batch-b']),2,'an autocommit read does not take the gate');
   for(const pending of [()=>db.prepare('UPDATE n_control SET revision=revision+1 WHERE name=?').bind('batch-a').run(),
    ()=>db.batch([db.prepare('UPDATE n_control SET revision=revision+1 WHERE name=?').bind('batch-b')])]){
    let settled=false;const work=pending().finally(()=>{settled=true;});
    let waiting=null;
    for(let i=0;i<40&&!waiting;i++){await sleep(50);waiting=(await admin.query("SELECT wait_event_type AS w FROM pg_stat_activity WHERE datname=$1 AND application_name=$2 AND wait_event_type='Lock'",[name,application])).rows[0]?.w??null;}
    assert.equal(waiting,'Lock','the handle\'s write waits on the gate row');assert.equal(settled,false);
    await holder.query('COMMIT');
    const r=await work;assert.equal((Array.isArray(r)?r[0]:r).meta.changes,1);
    await holder.query('BEGIN');await holder.query(GATE);
   }
  }finally{await holder.query('ROLLBACK').catch(()=>{});}
  assert.deepEqual((await other.query("SELECT name,revision FROM n_control WHERE name LIKE 'batch-%' ORDER BY name")).rows,[{name:'batch-a',revision:2},{name:'batch-b',revision:3}]);
 });
 await test('live handle: a failing batch rolls back every statement; a failing write rolls back; the handle stays usable',async()=>{
  await assert.rejects(db.batch([
   db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,1)').bind('rollback-1'),
   db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,1)').bind('rollback-2'),
   db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,1)').bind('rollback-1'),
  ]),error=>error instanceof PostgresError&&error.code==='23505');
  assert.equal(await count(['rollback-1','rollback-2']),0);
  await assert.rejects(db.prepare('UPDATE n_control SET enabled=2 WHERE name=?').bind('batch-a').run(),error=>error instanceof PostgresError&&error.code==='23514');
  assert.equal(await db.prepare('SELECT enabled FROM n_control WHERE name=?').bind('batch-a').first('enabled'),0);
  // A statement outside the dialect fails the batch before BEGIN: nothing runs.
  await assert.rejects(db.batch([db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,1)').bind('rollback-3'),db.prepare('PRAGMA foreign_key_check')]),D1PhysicalStatement);
  await assert.rejects(db.prepare('SELECT ifnull(etag,0) AS e FROM n_feed').all(),UnmappedStatement);
  await assert.rejects(db.prepare('SELECT name FROM n_control WHERE name=? AND revision=?').bind('x').all(),/Wrong number of parameter bindings \(1 bound, 2 expected\)/);
  await assert.rejects(db.exec('DELETE FROM n_control'),/exec\(\) is not supported/);
  assert.equal(await count(['rollback-3']),0);assert.equal(db.client.status,'I');
 });
 await test('live handle: meta exposes changes only; every other field throws',async()=>{
  const r=await db.prepare('UPDATE n_control SET revision=revision+1 WHERE name IN(?,?)').bind('batch-a','batch-b').run();
  assert.equal(r.success,true);assert.equal(r.meta.changes,2);assert.deepEqual(r.results,[]);
  for(const field of ['size_after','rows_read','rows_written','last_row_id','duration','changed_db','served_by'])assert.throws(()=>r.meta[field],error=>error instanceof D1OnlyMetaField&&error.field===field,field);
  assert.equal(JSON.stringify(r),'{"success":true,"results":[],"meta":{"changes":2}}');
  assert.equal((await db.prepare('SELECT name FROM n_control WHERE name=?').bind('batch-a').all()).meta.changes,0);
 });
 await test('live handle: concurrent calls are serialized in issue order on the one connection',async()=>{
  const client=db.client;let inFlight=0,most=0;
  for(const method of ['query','simple']){const original=client[method].bind(client);client[method]=async(...args)=>{inFlight++;most=Math.max(most,inFlight);try{return await original(...args);}finally{inFlight--;}};}
  const tally=db.prepare("SELECT COUNT(*) AS n FROM n_control WHERE name LIKE 'serial-%'");
  const calls=[];
  for(let k=0;k<12;k++){
   calls.push(db.batch([db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,?)').bind(`serial-${k}`,k),tally]));
   if(k===5)calls.push(db.prepare('INSERT INTO n_control(name,enabled,revision) VALUES(?,0,1)').bind('serial-0').run());
   calls.push(tally.first('n'));
  }
  const settled=await Promise.allSettled(calls);
  delete client.query;delete client.simple;
  assert.equal(most,1,'never two protocol exchanges in flight');
  const values=settled.map(s=>s.status==='fulfilled'?(Array.isArray(s.value)?s.value[1].results[0].n:s.value):s.reason.code);
  assert.deepEqual(values,[1,1,2,2,3,3,4,4,5,5,6,'23505',6,7,7,8,8,9,9,10,10,11,11,12,12]);
 });
 await test('live handle: R11 installs and drops the suite trigger; R2/R3 read JSON as text with NULL for null',async()=>{
  const create="CREATE TRIGGER reject_redelivery_stat BEFORE INSERT ON n_poll_stat WHEN NEW.redeliveries>0 BEGIN SELECT RAISE(ABORT,'fixture:redelivery_stat'); END";
  const stat=(bucket,redeliveries)=>db.prepare('INSERT INTO n_poll_stat(bucket,redeliveries) VALUES(?,?)').bind(bucket,redeliveries).run();
  await db.prepare(create).run();
  await assert.rejects(stat(1,1),/fixture:redelivery_stat/);await stat(2,0);
  await db.prepare('DROP TRIGGER reject_redelivery_stat').run();await stat(3,1);
  assert.deepEqual((await db.prepare('SELECT bucket FROM n_poll_stat ORDER BY bucket').all()).results,[{bucket:2},{bucket:3}]);
  const each=db.prepare('SELECT value FROM json_each(?)');
  assert.deepEqual((await each.bind('["a",null,"b"]').all()).results,[{value:'a'},{value:null},{value:'b'}]);
  assert.deepEqual((await each.bind(null).all()).results,[]);
  assert.deepEqual((await db.prepare("SELECT json_extract(value,'$.feed_id') AS id FROM json_each(?)").bind('[{"feed_id":"f1"},{"feed_id":null},{}]').all()).results,[{id:'f1'},{id:null},{id:null}]);
  await db.prepare('UPDATE n_feed_catalog SET admission_health_json=? WHERE feed_url=?').bind('{"a":"x","b":{"c":"y"},"n":null,"k":5}','https://t.example/feed').run();
  const extract=path=>db.prepare(`SELECT json_extract(admission_health_json,'${path}') AS v FROM n_feed_catalog WHERE feed_url=?`).bind('https://t.example/feed').first('v');
  assert.deepEqual([await extract('$.a'),await extract('$.b.c'),await extract('$.n'),await extract('$.missing')],['x','y',null,null]);
  // The pinned divergence: a JSON number reads as its text (SQLite returns 5).
  assert.equal(await extract('$.k'),'5');
 });
}finally{
 // Dispose order: the handle, every test client, then a bounded wait for zero
 // backends on the clone before DROP DATABASE (never WITH (FORCE)).
 const handleClient=db?.client;
 if(db)await db.close().catch(error=>{failed++;console.log('not ok handle close',error);});
 if(handleClient&&handleClient.closedBy!=='server'){failed++;console.log(`not ok the handle's connection closed by ${handleClient.closedBy}, not the server`);}
 for(const c of clients)await c.close().catch(()=>{});
 if(created){
  let remaining=[];
  for(let i=0;i<50;i++){remaining=(await admin.query('SELECT application_name FROM pg_stat_activity WHERE datname=$1',[name])).rows;if(!remaining.length)break;await sleep(100);}
  if(remaining.length){failed++;console.log(`not ok backends remain on ${name}: ${remaining.map(r=>r.application_name).join(',')}`);}
  await admin.simple(`DROP DATABASE ${name}`).then(()=>console.log(`dropped ${name}`),error=>{failed++;console.log(`not ok DROP DATABASE ${name}: ${error.message}`);});
 }
 await admin?.close();
}
if(failed){console.log(`${failed} failed`);process.exit(1);}
console.log('test-database: all passed');
