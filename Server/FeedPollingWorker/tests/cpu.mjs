import WebSocket from 'ws';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
export async function processCPU() {
  const {stdout}=await promisify(execFile)('ps',['-axo','pid=,ppid=,time=,comm=']);
  const workers=stdout.trim().split('\n').map(line=>line.trim().split(/\s+/)).filter(row=>Number(row[1])===process.pid&&row.slice(3).join(' ').endsWith('workerd'));
  if(workers.length!==1)throw Error('Expected one owned workerd process for CPU accounting');
  return {pid:Number(workers[0][0]),milliseconds:workers[0][2].split(':').reduce((sum,value)=>sum*60+Number(value),0)*1000};
}
export function summarizeCPU(profile, target) {
  const nodes=new Map(profile.nodes.map(n=>[n.id,n]));
  let idle=0,active=0;
  for(let i=0;i<profile.samples.length;i++){
    const micros=profile.timeDeltas[i]??0;
    if(nodes.get(profile.samples[i])?.callFrame.functionName==='(idle)')idle+=micros;else active+=micros;
  }
  return {target,profile_duration_ms:(profile.endTime-profile.startTime)/1000,sampled_active_ms:active/1000,sampled_idle_ms:idle/1000,samples:profile.samples.length,profile};
}
// DevTools sampling, not a claim about Cloudflare billing or Node-driver CPU.
export async function profileCPU(inspectorURL, name='polling-runtime') {
  const listing=new URL('/json/list',inspectorURL);listing.protocol='http:';
  const targets=await(await fetch(listing)).json();
  const target=targets.find(t=>t.title?.includes(name));
  if(!target)throw Error('CPU profiling target missing');
  const socket=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.once('open',resolve);socket.once('error',reject);});
  const pending=new Map();let id=0;
  socket.on('message',bytes=>{const message=JSON.parse(bytes);const waiter=pending.get(message.id);if(waiter){pending.delete(message.id);clearTimeout(waiter.timer);message.error?waiter.reject(Error(JSON.stringify(message.error))):waiter.resolve(message.result);}});
  const command=(method,params)=>new Promise((resolve,reject)=>{const request=++id;const timer=setTimeout(()=>{pending.delete(request);reject(Error('Profiler timeout: '+method));},30000);pending.set(request,{resolve,reject,timer});socket.send(JSON.stringify({id:request,method,params}));});
  try{await command('Profiler.enable');await command('Profiler.setSamplingInterval',{interval:1000});await command('Profiler.start');}catch(error){socket.close();throw error;}
  return async()=>{
    try{
      const {profile}=await command('Profiler.stop');
      return summarizeCPU(profile,target.title);
    }finally{socket.close();}
  };
}
