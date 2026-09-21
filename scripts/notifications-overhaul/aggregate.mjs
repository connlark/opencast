// Aggregate-only resource/cost projection. Missing dimensions are unavailable, never zero.
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
export const resourceIDs=['worker_requests','worker_cpu_ms','d1_rows_read','d1_rows_written','d1_gb_month','r2_class_a','r2_class_b','r2_gb_month','queue_operations','do_requests','do_gb_seconds','do_rows_read','do_rows_written','do_gb_month','logs_events'];
export function project(input) {
 if(!(input.window_seconds>0)) throw Error('window_seconds must be positive');
 const totals={},missing=[],costs={};
 for(const id of resourceIDs) {
  const value=input.resources[id],rate=input.rates[id];
  if(!Number.isFinite(value) || !rate || !Number.isFinite(rate.usd_per_unit) || !Number.isFinite(rate.remaining_included)) {missing.push(id);continue;}
  if(value<0 || rate.usd_per_unit<0 || rate.remaining_included<0)throw Error('negative resource/rate');
  // Storage observations are average GB; rates express dollars per GB-month.
  totals[id]=id.endsWith('_gb_month')?value:value*2592000/input.window_seconds;
  costs[id]=Math.max(0,totals[id]-rate.remaining_included)*rate.usd_per_unit;
 }
 const known=Object.values(costs).reduce((a,b)=>a+b,0);
 return {schema_version:1,window_seconds:input.window_seconds,monthly_resources:totals,monthly_costs_usd:costs,known_subtotal_usd:known,unavailable:missing,complete:missing.length===0,total_usd:missing.length===0?known:null,review_threshold_usd:25,review:known>25?'required':missing.length?'insufficient_data':'below_threshold'};
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) console.log(JSON.stringify(project(JSON.parse(await readFile(process.argv[2],'utf8'))),null,2));
