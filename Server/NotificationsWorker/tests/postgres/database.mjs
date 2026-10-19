// D1-shaped test-side database over one owner connection to a local PostgreSQL
// clone (promoted from the earlier PostgreSQL integration harness's D1 shim,
// without its ledger, migration-batch deferral or lineage states: a clone of
// the template is installed, so there is nothing to replay). SQL goes through
// sql.mjs translate(), the closed fixture dialect; owner privileges, like D1's
// direct test access. Every call is serialized on the one connection. Reads
// autocommit; every write and every batch is ONE transaction that first takes
// the dispatch gate, as the Worker does (postgres/README.md: every runtime
// write locks the singleton n_poll_dispatch row first).
import {Client,gatedTransaction} from './pg.mjs';
import {translate} from './sql.mjs';
// Unqualified suite table names resolve in the opencast schema.
export const SEARCH_PATH='opencast, pg_catalog';
export class D1OnlyMetaField extends Error {
 constructor(field){super(`meta.${field} is D1-only; the PostgreSQL handle reports meta.changes only`);this.name='D1OnlyMetaField';this.field=field;}
}
// meta.changes is PostgreSQL's command count (it excludes trigger rows D1
// counts). Any other field throws, so a PostgreSQL reader of size_after,
// rows_read and the like fails instead of passing on an absent value. toJSON
// and then are protocol probes (JSON.stringify, await), not fields.
const PROBES=new Set(['toJSON','then']);
const meta=changes=>new Proxy({changes},{get(target,key,receiver){
 if(key==='changes'||typeof key==='symbol')return Reflect.get(target,key,receiver);
 if(PROBES.has(key))return undefined;
 throw new D1OnlyMetaField(key);
}});
const result=r=>({success:true,results:r.rows,meta:meta(r.changes)});
// D1's bind() rules: numbers and strings as given, booleans as 0/1, null,
// byte arrays and buffers as blobs; anything else (undefined included) throws.
function bindValue(value){
 if(typeof value==='number'||typeof value==='string'||value===null)return value;
 if(typeof value==='boolean')return value?1:0;
 if(Array.isArray(value)&&value.every(b=>typeof b==='number'&&b>=0&&b<256))return Uint8Array.from(value);
 if(value instanceof ArrayBuffer)return new Uint8Array(value);
 if(ArrayBuffer.isView(value))return new Uint8Array(value.buffer,value.byteOffset,value.byteLength);
 throw new TypeError(`D1_TYPE_ERROR: Type '${typeof value}' not supported for value '${value}'`);
}
const plans=new Map();
const planOf=sql=>{if(!plans.has(sql))plans.set(sql,translate(sql));return plans.get(sql);};
export class Database {
 constructor({host='127.0.0.1',port,database,user,password,application='opencast-test-owner'}){
  this.options={host,port,database,user,password,application,searchPath:SEARCH_PATH};
  this.queue=Promise.resolve();this.client=null;this.closed=false;
 }
 // One promise queue: the owner connection runs one call at a time, in order.
 serial(work){const next=this.queue.then(work,work);this.queue=next.catch(()=>{});return next;}
 async connection(){
  if(this.closed)throw Error(`database ${this.options.database}: handle is closed`);
  this.client??=await Client.connect(this.options);
  return this.client;
 }
 prepare(sql){if(typeof sql!=='string')throw new TypeError('prepare() takes SQL text');return new Statement(this,sql,[]);}
 async batch(statements){
  if(!Array.isArray(statements))throw new TypeError('batch() takes an array of prepared statements');
  // Every statement is translated before BEGIN: one that does not map runs nothing.
  const units=statements.map(s=>{if(!(s instanceof Statement)||s.db!==this)throw new TypeError('batch() takes statements prepared on this database');return s.unit();});
  const out=await this.serial(async()=>gatedTransaction(await this.connection(),units));
  return out.map(result);
 }
 async exec(sql){throw new Error(`exec() is not supported on the PostgreSQL test handle; use prepare(): ${sql}`);}
 // Terminate (the client lets the server close first) after queued calls finish.
 close(){return this.serial(async()=>{this.closed=true;const c=this.client;this.client=null;if(c)await c.close();});}
}
class Statement {
 constructor(db,sql,values){this.db=db;this.sql=sql;this.values=values;}
 bind(...values){return new Statement(this.db,this.sql,values.map(bindValue));}
 unit(){
  const plan=planOf(this.sql);
  if(this.values.length!==plan.parameters)throw new RangeError(`Wrong number of parameter bindings (${this.values.length} bound, ${plan.parameters} expected): ${this.sql}`);
  return [plan.pg,this.values,plan.script===true,plan.read];
 }
 async execute(){
  const unit=this.unit();
  return this.db.serial(async()=>{
   const client=await this.db.connection();
   if(unit[3])return client.query(unit[0],unit[1]);
   const [r]=await gatedTransaction(client,[unit]);return r;
  });
 }
 async first(column){
  const r=await this.execute();
  if(!r.rows.length)return null;
  if(column===undefined)return r.rows[0];
  if(r.rows[0][column]===undefined)throw new Error(`D1_COLUMN_NOTFOUND: Column not found (${column})`);
  return r.rows[0][column];
 }
 async all(){return result(await this.execute());}
 // D1's run() and all() return the same shape.
 async run(){return result(await this.execute());}
 async raw(options){const r=await this.execute();return [...(options?.columnNames?[r.columns]:[]),...r.values];}
}
