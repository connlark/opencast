// Minimal PostgreSQL v3 wire client for the test-side handle, the proxy's side
// writes and fixture management (promoted from the earlier PostgreSQL
// integration harness's wire client). SCRAM-SHA-256 with the server's proof
// verified; trust only for a connection opened without a password. Text-format
// results with their type OIDs; typed or untyped parameters. node: built-ins
// only.
import net from 'node:net';
import {once} from 'node:events';
import {promisify} from 'node:util';
import {createHash,createHmac,pbkdf2,randomBytes,timingSafeEqual} from 'node:crypto';
const i32=n=>{const b=Buffer.alloc(4);b.writeInt32BE(n);return b;};
const i16=n=>{const b=Buffer.alloc(2);b.writeInt16BE(n);return b;};
const cstr=s=>Buffer.from(s+'\0');
const frame=(kind,body)=>Buffer.concat([Buffer.from(kind),i32(body.length+4),body]);
export const OID={bool:16,bytea:17,int8:20,int2:21,int4:23,text:25,json:114,float4:700,float8:701,unknown:705,numeric:1700};
// Terminate, then wait this long for the server to close before destroying.
export const CLOSE_FALLBACK_MS=1000;
export class PostgresError extends Error {
 constructor(fields){super(fields.M??'PostgreSQL error');this.name='PostgresError';this.code=fields.C;this.fields=fields;}
}
// The client refused the server: a SCRAM rule failed or an authentication
// request it does not accept arrived. The connection is destroyed.
export class AuthenticationRefused extends Error {
 constructor(reason){super(`authentication refused: ${reason}`);this.name='AuthenticationRefused';this.reason=reason;}
}
const refuse=reason=>{throw new AuthenticationRefused(reason);};
function errorFields(body){const out={};let i=0;while(i<body.length&&body[i]!==0){const k=String.fromCharCode(body[i]);const end=body.indexOf(0,i+1);out[k]=body.subarray(i+1,end).toString();i=end+1;}return out;}
// Parameter encoding by JS value (text format): safe integer -> int8, other
// number -> float8, string -> text, boolean -> int8 0/1, bytes -> bytea, null untyped.
export function encodeParameter(value){
 if(value===null||value===undefined)return {oid:0,text:null};
 if(typeof value==='boolean')return {oid:OID.int8,text:value?'1':'0'};
 if(typeof value==='number'){
  if(Number.isSafeInteger(value))return {oid:OID.int8,text:String(value)};
  if(!Number.isFinite(value))throw TypeError('non-finite number parameter');
  return {oid:OID.float8,text:String(value)};
 }
 if(typeof value==='bigint')return {oid:OID.int8,text:value.toString()};
 if(typeof value==='string')return {oid:OID.text,text:value};
 if(value instanceof ArrayBuffer)value=new Uint8Array(value);
 if(ArrayBuffer.isView(value))return {oid:OID.bytea,text:'\\x'+Buffer.from(value.buffer,value.byteOffset,value.byteLength).toString('hex')};
 throw TypeError('unsupported parameter type '+typeof value);
}
// D1-shaped values: integers as safe Numbers, bool as 0/1, bytea as Uint8Array.
export function decodeValue(oid,text){
 if(text===null)return null;
 switch(oid){
  case OID.int2:case OID.int4:case OID.int8:case OID.numeric:case OID.float4:case OID.float8:{
   const n=Number(text);
   if(oid!==OID.float4&&oid!==OID.float8&&!(Number.isSafeInteger(n)||(oid===OID.numeric&&Number.isFinite(n)&&String(n)===text)))throw RangeError(`unsafe numeric ${text}`);
   return n;
  }
  case OID.bool:return text==='t'?1:0;
  case OID.bytea:return new Uint8Array(Buffer.from(text.slice(2),'hex'));
  default:return text;
 }
}
// SCRAM-SHA-256 (RFC 5802, RFC 7677), client side, channel binding "n" (no
// TLS locally). Pure steps, so the RFC 7677 vector and a fake server can pin
// every rule. The username stays empty as libpq sends it: PostgreSQL
// authenticates the startup packet's user.
const SCRAM_PRINTABLE=/^[\x21-\x2b\x2d-\x7e]+$/; // RFC 5802 "printable": no comma
const BASE64=/^(?=.)(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const GS2='n,,',GS2_BASE64=Buffer.from(GS2).toString('base64');
const hmac=(key,text)=>createHmac('sha256',key).update(text).digest();
const pbkdf2Async=promisify(pbkdf2);
export function scramClientFirst({nonce=randomBytes(18).toString('base64'),user=''}={}){
 if(!SCRAM_PRINTABLE.test(nonce))throw TypeError('SCRAM nonce must be printable and comma-free');
 const bare=`n=${user.replace(/=/g,'=3D').replace(/,/g,'=2C')},r=${nonce}`;
 return {nonce,bare,message:GS2+bare};
}
// Exactly r, s, i in that order (PostgreSQL sends no extension); a leading
// m= (mandatory extension) or any other shape refuses.
export function parseServerFirst(text,clientNonce){
 const m=/^r=([^,]*),s=([^,]*),i=([^,]*)$/.exec(text);
 if(!m)refuse('malformed server-first-message');
 const [,nonce,salt,count]=m;
 if(!SCRAM_PRINTABLE.test(nonce))refuse('malformed server nonce');
 if(!nonce.startsWith(clientNonce)||nonce.length<=clientNonce.length)refuse('server nonce does not extend the client nonce');
 if(!BASE64.test(salt))refuse('malformed salt');
 if(!/^[1-9][0-9]{0,9}$/.test(count)||Number(count)>0x7fffffff)refuse('malformed iteration count');
 return {nonce,salt:Buffer.from(salt,'base64'),iterations:Number(count)};
}
// The password is used without SASLprep, which maps every ASCII string to
// itself; anything else is refused rather than half-normalized.
export async function scramClientFinal({password,clientNonce,clientFirstBare,serverFirst}){
 if(typeof password!=='string'||!/^[\x01-\x7f]*$/.test(password))throw TypeError('SCRAM password must be an ASCII string (no SASLprep)');
 const {nonce,salt,iterations}=parseServerFirst(serverFirst,clientNonce);
 const salted=await pbkdf2Async(password,salt,iterations,32,'sha256');
 const clientKey=hmac(salted,'Client Key');
 const storedKey=createHash('sha256').update(clientKey).digest();
 const withoutProof=`c=${GS2_BASE64},r=${nonce}`;
 const authMessage=`${clientFirstBare},${serverFirst},${withoutProof}`;
 const clientSignature=hmac(storedKey,authMessage);
 const proof=Buffer.from(clientKey.map((b,k)=>b^clientSignature[k]));
 const serverSignature=hmac(hmac(salted,'Server Key'),authMessage);
 return {message:`${withoutProof},p=${proof.toString('base64')}`,serverSignature};
}
// The server proves it holds the verifier: v= must equal ServerSignature.
export function verifyServerFinal(text,serverSignature){
 if(text.startsWith('e='))refuse(`server-final error ${text.slice(2)}`);
 const m=/^v=([^,]*)$/.exec(text);
 if(!m||!BASE64.test(m[1]))refuse('malformed server-final-message');
 const v=Buffer.from(m[1],'base64');
 if(v.length!==serverSignature.length||!timingSafeEqual(v,serverSignature))refuse('server signature mismatch');
}
const AUTH_NAMES={0:'Ok',2:'KerberosV5',3:'CleartextPassword',5:'MD5Password',7:'GSS',8:'GSSContinue',9:'SSPI',10:'SASL',11:'SASLContinue',12:'SASLFinal'};
export class Client {
 // Startup parameters: user, database, application_name and, when given,
 // search_path (the handle's unqualified table names resolve through it).
 static async connect({host='127.0.0.1',port,user,password,database,application='opencast-test',searchPath}){
  if(!user||!database)throw TypeError('connect needs user and database');
  const c=new Client();c.socket=net.connect({host,port});c.socket.setNoDelay(true);
  c.buffer=Buffer.alloc(0);c.waiters=[];c.messages=[];c.closed=false;c.status=null;c.closedBy=null;c.mechanism=null;
  c.socket.on('data',chunk=>{c.buffer=Buffer.concat([c.buffer,chunk]);c.pump();});
  c.socket.on('close',()=>{c.closed=true;c.closedBy??='server';c.pump();});
  c.socket.on('error',()=>{});
  await once(c.socket,'connect');
  try{
   const params=[['user',user],['database',database],['application_name',application],...(searchPath==null?[]:[['search_path',searchPath]])];
   const body=Buffer.concat([...params.flatMap(([k,v])=>[cstr(k),cstr(String(v))]),Buffer.from([0])]);
   c.socket.write(Buffer.concat([i32(body.length+8),i32(196608),body]));
   await c.authenticate(password);
   for(;;){const m=await c.next();
    if(m.kind==='E')throw new PostgresError(errorFields(m.body));
    if(m.kind==='Z'){c.status=String.fromCharCode(m.body[0]);break;}
    if(!'SKN'.includes(m.kind))refuse(`unexpected message ${m.kind} after authentication`);
   }
  }catch(error){c.closedBy??='client';c.socket.destroy();throw error;}
  return c;
 }
 // One authentication message: R with the expected code, or E (raised as the
 // server's error, 28P01 for a wrong password). Anything else refuses.
 async auth(expected){
  const m=await this.next();
  if(m.kind==='E')throw new PostgresError(errorFields(m.body));
  if(m.kind!=='R'||m.body.length<4)refuse(`unexpected message ${m.kind} during authentication`);
  const code=m.body.readInt32BE(0);
  if(expected!==undefined&&code!==expected)refuse(`authentication request ${code} (${AUTH_NAMES[code]??'unknown'}) where ${expected} (${AUTH_NAMES[expected]}) was expected`);
  return {code,data:m.body.subarray(4)};
 }
 // With a password only SASL SCRAM-SHA-256 is accepted: no cleartext, no MD5,
 // and no trust (AuthenticationOk first would skip the server's proof).
 async authenticate(password){
  const {code,data}=await this.auth();
  if(code===0){if(password!=null)refuse('server skipped authentication for a password connection');this.mechanism='trust';return;}
  if(code!==10)refuse(`authentication request ${code} (${AUTH_NAMES[code]??'unknown'})`);
  if(password==null)refuse('server requested SASL but no password was given');
  const mechanisms=data.toString().split('\0');
  if(mechanisms.length<2||mechanisms.at(-1)!==''||mechanisms.at(-2)!=='')refuse('malformed SASL mechanism list');
  if(!mechanisms.includes('SCRAM-SHA-256'))refuse(`no SCRAM-SHA-256 among ${mechanisms.filter(Boolean).join(',')}`);
  const first=scramClientFirst();
  this.socket.write(frame('p',Buffer.concat([cstr('SCRAM-SHA-256'),i32(Buffer.byteLength(first.message)),Buffer.from(first.message)])));
  const serverFirst=(await this.auth(11)).data.toString();
  const final=await scramClientFinal({password,clientNonce:first.nonce,clientFirstBare:first.bare,serverFirst});
  this.socket.write(frame('p',Buffer.from(final.message)));
  verifyServerFinal((await this.auth(12)).data.toString(),final.serverSignature);
  await this.auth(0);this.mechanism='SCRAM-SHA-256';
 }
 pump(){
  while(this.buffer.length>=5){const size=this.buffer.readInt32BE(1);
   if(size<4){this.buffer=Buffer.alloc(0);this.closedBy??='client';this.socket.destroy();break;}
   if(this.buffer.length<size+1)break;
   this.messages.push({kind:String.fromCharCode(this.buffer[0]),body:this.buffer.subarray(5,size+1)});this.buffer=this.buffer.subarray(size+1);}
  while(this.waiters.length&&(this.messages.length||this.closed)){const w=this.waiters.shift();
   if(this.messages.length)w.resolve(this.messages.shift());else w.reject(Error('PostgreSQL connection closed'));}
 }
 next(){return new Promise((resolve,reject)=>{this.waiters.push({resolve,reject});this.pump();});}
 // Collect one result set up to ReadyForQuery; the first error wins.
 async collect(){
  let fields=null,rows=[],tag=null,error=null;const results=[];
  for(;;){const m=await this.next();
   switch(m.kind){
    case 'T':{const n=m.body.readInt16BE(0);let o=2;fields=[];for(let k=0;k<n;k++){const end=m.body.indexOf(0,o);const name=m.body.subarray(o,end).toString();o=end+1;const oid=m.body.readInt32BE(o+6);o+=18;fields.push({name,oid});}rows=[];break;}
    case 'D':{const n=m.body.readInt16BE(0);let o=2;const row=[];for(let k=0;k<n;k++){const len=m.body.readInt32BE(o);o+=4;if(len===-1)row.push(null);else{row.push(m.body.subarray(o,o+len).toString());o+=len;}}rows.push(row);break;}
    case 'C':tag=m.body.subarray(0,m.body.length-1).toString();results.push({fields,rows,tag});fields=null;rows=[];break;
    case 'I':results.push({fields:null,rows:[],tag:null});break;
    case 'E':error??=new PostgresError(errorFields(m.body));break;
    case 'Z':this.status=String.fromCharCode(m.body[0]);if(error)throw error;return results;
    default:break; // 1 2 n t s N S K: no data needed
   }
  }
 }
 // Simple query: owner DDL scripts and multi-statement fixture SQL.
 async simple(sql){this.socket.write(frame('Q',cstr(sql)));return this.collect();}
 // Extended query, unnamed statement, text formats. Returns D1-shaped rows,
 // ordered column names, the affected count and the command tag.
 async query(sql,values=[]){
  const params=values.map(encodeParameter);
  const parse=frame('P',Buffer.concat([cstr(''),cstr(sql),i16(params.length),...params.map(p=>i32(p.oid))]));
  const bind=frame('B',Buffer.concat([cstr(''),cstr(''),i16(0),i16(params.length),...params.map(p=>p.text===null?i32(-1):Buffer.concat([i32(Buffer.byteLength(p.text)),Buffer.from(p.text)])),i16(0)]));
  const describe=frame('D',Buffer.concat([Buffer.from('P'),cstr('')]));
  const execute=frame('E',Buffer.concat([cstr(''),i32(0)]));
  this.socket.write(Buffer.concat([parse,bind,describe,execute,frame('S',Buffer.alloc(0))]));
  const [result]=await this.collect();
  return shape(result);
 }
 // Pipelined units, as tokio-postgres sends a write transaction: every
 // Parse/Bind/Describe/Execute/Sync written before any reply is read. Returns
 // one {result|error} per unit; a closed connection ends the list early.
 async pipeline(list){
  const units=list.map(([sql,values=[]])=>{const params=values.map(encodeParameter);return Buffer.concat([
   frame('P',Buffer.concat([cstr(''),cstr(sql),i16(params.length),...params.map(p=>i32(p.oid))])),
   frame('B',Buffer.concat([cstr(''),cstr(''),i16(0),i16(params.length),...params.map(p=>p.text===null?i32(-1):Buffer.concat([i32(Buffer.byteLength(p.text)),Buffer.from(p.text)])),i16(0)])),
   frame('D',Buffer.concat([Buffer.from('P'),cstr('')])),frame('E',Buffer.concat([cstr(''),i32(0)])),frame('S',Buffer.alloc(0))]);});
  this.socket.write(Buffer.concat(units));
  const out=[];
  for(let k=0;k<units.length;k++){try{const [r]=await this.collect();out.push({result:shape(r)});}catch(error){out.push({error});if(this.closed)break;}}
  return out;
 }
 // Parse and Describe only: parameter OIDs and result columns, nothing executed.
 async describe(sql,oids=[]){
  this.socket.write(Buffer.concat([frame('P',Buffer.concat([cstr(''),cstr(sql),i16(oids.length),...oids.map(i32)])),frame('D',Buffer.concat([Buffer.from('S'),cstr('')])),frame('S',Buffer.alloc(0))]));
  let parameters=null,fields=null,error=null;
  for(;;){const m=await this.next();
   if(m.kind==='t'){const n=m.body.readInt16BE(0);parameters=[];for(let k=0;k<n;k++)parameters.push(m.body.readInt32BE(2+4*k));}
   else if(m.kind==='T'){const n=m.body.readInt16BE(0);let o=2;fields=[];for(let k=0;k<n;k++){const end=m.body.indexOf(0,o);fields.push({name:m.body.subarray(o,end).toString(),oid:m.body.readInt32BE(end+1+6)});o=end+1+18;}}
   else if(m.kind==='n')fields=[];
   else if(m.kind==='E')error??=new PostgresError(errorFields(m.body));
   else if(m.kind==='Z'){this.status=String.fromCharCode(m.body[0]);if(error)throw error;return {parameters,fields};}
  }
 }
 // Terminate, then let the server close first (its TIME_WAIT, not the
 // client's: the arm-27 lesson); end only after that close, with a bounded
 // fallback destroy. closedBy records which side ended the connection.
 async close(){
  if(this.closed)return;
  const closed=new Promise(resolve=>this.socket.once('close',resolve));
  const fallback=setTimeout(()=>{this.closedBy??='fallback';this.socket.destroy();},CLOSE_FALLBACK_MS);
  this.socket.write(frame('X',Buffer.alloc(0)));
  await closed;clearTimeout(fallback);
 }
}
// D1-shaped rows (objects, the last duplicate name wins as in D1) and the same
// rows as arrays for raw().
export function shape(result){
 const fields=result?.fields??[];
 const values=(result?.rows??[]).map(row=>fields.map((f,k)=>decodeValue(f.oid,row[k])));
 const rows=values.map(row=>Object.fromEntries(fields.map((f,k)=>[f.name,row[k]])));
 const tag=result?.tag??'';const m=tag.match(/(\d+)$/);
 return {rows,values,columns:fields.map(f=>f.name),types:fields.map(f=>f.oid),changes:m&&!/^SELECT/.test(tag)?Number(m[1]):0,tag};
}
export const GATE='SELECT 1/COUNT(*) AS guard FROM (SELECT id FROM opencast.n_poll_dispatch WHERE id=1 FOR UPDATE) AS gate';
// One gate-first transaction for a test-side write or batch, as D1 serializes
// it. Each entry is [sql, values] or [script, [], true] for a simple-query
// owner script (R11's trigger DDL); an error rolls back and is rethrown.
export async function gatedTransaction(client,statements){
 await client.query('BEGIN');
 try{
  await client.query(GATE);
  const out=[];
  for(const [sql,values,script] of statements)out.push(script?shape((await client.simple(sql)).at(-1)):await client.query(sql,values));
  await client.query('COMMIT');return out;
 }catch(error){await client.query('ROLLBACK').catch(()=>{});throw error;}
}
