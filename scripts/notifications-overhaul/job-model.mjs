// Phase-0 contract oracle, not production authentication or persistence.
import { H,payloadDigest } from './encoding.mjs';
export class JobModel {
  constructor(clock) { this.clock=clock; this.interests=new Map(); this.runs=new Map(); this.receipts=new Map(); this.deleted=new Set(); }
  issue({install,operation,producer,environment='development',ticket},authenticatedInstall=install) {
    if(authenticatedInstall!==install || this.deleted.has(install)) throw Error('unauthorized_install');
    if(!['ad_analysis','remote_transcription'].includes(producer)) throw Error('unsupported_producer');
    if(!ticket || ticket.producer!==producer || ticket.operation!==operation || ticket.environment!==environment || ticket.expires<=this.clock.now) throw Error('requester_ticket_invalid');
    const key=`${install}/${operation}`; const existing=this.interests.get(key);
    if(existing) {
      if(existing.producer!==producer || existing.requester!==ticket.requester) throw Error('operation_conflict');
      return existing;
    }
    const id=H(['interest-v1',environment,install,'1',operation,'1']);
    const interest={id,generation:1,epoch:1,key,install,operation,producer,environment,requester:ticket.requester,issued:this.clock.now,acceptBefore:this.clock.now+1800,registerBefore:this.clock.now+604800,state:'issued',run:null};
    this.interests.set(key,interest); return interest;
  }
  accept(interest,{producer,environment,requester,run,acceptedAt=this.clock.now},trusted=true) {
    if(!trusted || interest.producer!==producer || interest.environment!==environment || interest.requester!==requester) throw Error('unauthorized_producer');
    if(this.deleted.has(interest.install) || ['revoked','cancelled','superseded','expired'].includes(interest.state)) throw Error('revoked');
    if(interest.run && interest.run!==run) throw Error('grant_replay');
    if(acceptedAt<interest.issued || acceptedAt>=interest.acceptBefore || this.clock.now>=interest.registerBefore) throw Error('grant_expired');
    interest.run=run; interest.acceptedAt=acceptedAt;
    if(interest.state!=='seen') interest.state='registered';
    return interest;
  }
  decline(interest,binding,{reason='notifications_unavailable',mayHaveRegistered=false,safeSuppressionReceipt=false}={}) {
    if(interest.producer!==binding.producer || interest.environment!==binding.environment || interest.requester!==binding.requester) throw Error('unauthorized_producer');
    const response={schema_version:1,operation_id:interest.operation,interest_id:interest.id,interest_generation:interest.generation};
    if((mayHaveRegistered || interest.run) && !safeSuppressionReceipt) return {...response,state:'pending'};
    interest.state='cancelled';interest.reason='attachment_rejected';
    return {...response,state:'rejected',reason};
  }
  complete({run,producer='ad_analysis',outcome='completed',fingerprint='same',chainPending=false,billingPending=false,oldExpiry=null}) {
    if(chainPending) return null;
    if(this.runs.has(run)) return this.runs.get(run);
    const completed=this.clock.now;
    const record={run,producer,outcome,fingerprint,completed,expires:completed+21600,resultExpires:oldExpiry ?? completed+(producer==='remote_transcription'?604800:outcome==='completed'?86400:1800),result:outcome==='completed',billingPending,outbox:!['cancelled','superseded'].includes(outcome),localCached:false};
    this.runs.set(run,record); return record;
  }
  event(interest) {
    const run=this.runs.get(interest.run);
    if(!run || !run.outbox || interest.state!=='registered' || this.deleted.has(interest.install) || this.clock.now>=run.expires) return null;
    const kind=`${interest.producer}.${run.outcome}`;
    return {schema_version:1,environment:interest.environment,source:interest.producer,event_id:H(['job-v1',interest.environment,interest.producer,run.run,interest.operation,interest.id,kind]),kind,occurred_at:run.completed,eligible_at:run.completed,expires_at:run.expires,routing:{interest_id:interest.id,interest_generation:interest.generation,operation_id:interest.operation,run_id:run.run},data:run.outcome==='completed'?{job_handle:run.run,result_expires_at:run.resultExpires,title:'Result ready',body:'The server result is ready.'}:{job_handle:run.run,failure_code:'processing_failed',title:'Result unavailable',body:'Open the operation for details.'}};
  }
  ingest(event) {
    const digest=payloadDigest(event); const prior=this.receipts.get(event.event_id);
    if(prior && prior.digest!==digest) throw Error('event_conflict');
    if(this.clock.now>=event.expires_at) throw Error('event_expired');
    const receipt=prior??{id:`receipt-${this.receipts.size+1}`,digest}; this.receipts.set(event.event_id,receipt); return receipt.id;
  }
  seen(interest,install=interest.install) { if(install!==interest.install) throw Error('unauthorized_install'); interest.state='seen'; }
  revoke(interest,install=interest.install) { if(install!==interest.install) throw Error('unauthorized_install'); interest.state='revoked'; }
  delete(install) { this.deleted.add(install); for(const i of this.interests.values()) if(i.install===install) i.state='revoked'; }
  purge(run) { if(this.clock.now>=run.resultExpires) run.result=false; if(this.clock.now>=run.expires) run.outbox=false; }
  ack(run) { if(!run.localCached) throw Error('not_durably_imported'); run.result=false; }
  tap(run) { return run.localCached?'local':run.result && this.clock.now<run.resultExpires?'fetch_authorized':'unavailable_explicit_retry'; }
}
export function clientOwner({optIn,capability=true,setup='accepted',persistedOwner,attachment,operation,interestId,generation}) {
  if(attachment?.state==='rejected' && attachment.operation_id===operation && attachment.interest_id===interestId && attachment.interest_generation===generation) return 'local';
  if(persistedOwner) return persistedOwner;
  return optIn && capability && setup!=='definite_failure'?'remote':'local';
}
export function localSummary(operations) { return operations.filter(x=>x.owner==='local' && !x.cancelled).map(x=>x.id); }
export function foreground({visibleOperation,eventOperation}) { return {ingest:true,banner:visibleOperation!==eventOperation}; }
export function deliveryStep(delivery,endpoint,apns,clock,{enabled=true,eligible=true}={}) {
  if(delivery.state==='accepted') return 'accepted';
  if(clock.now>=delivery.expires) return delivery.state='expired';
  if(!eligible) return delivery.state='suppressed';
  if(!enabled) return delivery.state;
  const generation=endpoint.generation;
  try {
    const reply=apns.send({id:delivery.id,collapse:delivery.collapse,expiration:delivery.expires,generation});
    if(reply.status===200) return delivery.state='accepted';
    if(reply.status===410) {
      if(endpoint.generation!==generation || reply.timestamp && reply.timestamp<endpoint.registeredAt) return delivery.state='pending';
      endpoint.enabled=false; return delivery.state='permanent_failure';
    }
    if(reply.status===403 || reply.reason==='BadCertificateEnvironment') { delivery.pauseLane=true; return delivery.state='pending'; }
    return delivery.state=reply.status===429 || reply.status>=500?'pending':'permanent_failure';
  } catch { return delivery.state='uncertain'; }
}
