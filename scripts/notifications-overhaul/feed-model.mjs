// Executable policy oracle only. This is deliberately not imported by a Worker.
export class FeedModel {
  constructor(clock) { this.clock=clock; this.history=new Map(); this.fingerprints=new Set(); this.pending=new Map(); this.events=new Map(); this.generation=0; this.epoch=1; this.firstSeen=new Map(); this.lastComplete=null; this.validator=null; }
  scan(items,{initial=false,fault,status=200,epoch=this.epoch,validator='"validated"'}={}) {
    const now=this.clock.now;
    for(const item of items) if(!this.firstSeen.has(item.id)) this.firstSeen.set(item.id,now);
    if(fault || epoch!==this.epoch) return [];
    if(status===304) return []; // Use notModified for fenced per-interest absence evidence.
    const decisions=[]; const present=new Set(items.map(x=>x.id));
    for(const [id] of this.pending) if(!present.has(id)) this.pending.delete(id);
    for(const item of items) {
      if(this.history.has(item.id)) { decisions.push({id:item.id,reason:this.history.get(item.id).title===item.title?'known_identity':'metadata_only'}); continue; }
      const first=this.firstSeen.get(item.id); const valid=Number.isSafeInteger(item.date);
      let reason, eligible=first;
      if(initial) reason='baseline';
      else if(this.fingerprints.has(item.fingerprint)) reason='identity_churn';
      else if(valid && item.date < first-259200) reason='stale';
      else if(valid && item.date>first+600 && item.date<=first+604800) { reason='future'; eligible=item.date; this.pending.set(item.id,{...item,first,eligible,generation:this.generation+1}); }
      else { reason=valid && item.date>first+604800?'anomalous_date':valid?'recent':'undated'; this.events.set(item.id,{...item,first,eligible,expires:eligible+86400,generation:this.generation+1,reason}); }
      decisions.push({id:item.id,reason,first,eligible}); this.history.set(item.id,item); this.fingerprints.add(item.fingerprint);
    }
    this.generation++; this.lastComplete=now; this.validator=validator; return decisions;
  }
  notModified({requestValidator,expectedGeneration,epoch=this.epoch,startedAt=this.clock.now,interests=[]}) {
    if(!this.generation || !requestValidator || requestValidator!==this.validator || expectedGeneration!==this.generation || epoch!==this.epoch) return false;
    this.lastComplete=this.clock.now;
    for(const interest of interests) if(interest.enabled && !interest.deleted && interest.activated<=startedAt && interest.generation===interest.deliveryGeneration) {
      interest.absenceAt=startedAt;interest.absenceGeneration=this.generation;
    }
    return true;
  }
  releaseDue() {
    for(const [id,item] of this.pending) if(item.eligible<=this.clock.now) {
      this.events.set(id,{...item,expires:item.eligible+86400,reason:'future_released'}); this.pending.delete(id);
    }
  }
  recipient(event,interest) {
    if(!interest.enabled || interest.deleted || interest.generation!==interest.deliveryGeneration) return false;
    if(this.clock.now>=event.expires || interest.activated>event.eligible) return false;
    if(Number.isSafeInteger(event.date) && event.reason!=='anomalous_date') return event.date>interest.activated;
    return interest.absenceAt>=interest.activated && interest.absenceAt<event.first;
  }
  presentation(events) {
    const sorted=[...events].sort((a,b)=>a.eligible-b.eligible || a.id.localeCompare(b.id));
    return sorted.length>3?[{kind:'group',members:sorted.map(x=>x.id),route:sorted.at(-1).id}]:sorted.map(x=>({kind:'episode',members:[x.id],route:x.id}));
  }
}
// Storage planning oracle, not a bounded-memory scanner. Actual spill/merge lives in the packaged observation engine.
export function planCandidates(decisions) {
 const counts={},candidates=[];
 for(const decision of decisions) {
  counts[decision.reason]=(counts[decision.reason]??0)+1;
  if(['recent','undated','anomalous_date','future'].includes(decision.reason)) candidates.push(decision);
 }
 const overflow=candidates.length>1000;
 return {counts,candidateCount:candidates.length,storage:overflow?'r2':'d1',d1Rows:overflow?[]:candidates,r2Records:overflow?candidates:[]};
}
export function cadence({now,created,lastCredible,cadenceSeconds=0,credibleGaps=0}) {
  if(now-created<604800 || lastCredible!=null && now-lastCredible<=Math.max(7776000,credibleGaps>=3?cadenceSeconds*2:0)) return 300;
  return lastCredible!=null && now-lastCredible>=31536000 ? 3600:1800;
}
export function retryAfter(value,now) {
  const parsed=/^\d+$/.test(value)?now+Number(value):Date.parse(value)/1000;
  return Number.isFinite(parsed)?Math.max(now,parsed):now+60;
}
