/** Synthetic stream, never genuine candidate names or hosted accounts. */
import {CITIES} from './core.mjs';
export function demoSource(){
 let seq=0,offline=false;const data=CITIES.map((c,i)=>({...c,counts:i===0?[320,280]:i===1?[240,186,111,63]:i===2?[287,253]:[211,183,126,80],other:{blank:12+i,invalid:8+i,undisclosed:17+i,refused:9+i},pending:3+i,excluded:2,at:new Date().toISOString()}));
 const load=async(audience='codes')=>{if(offline)throw new Error('Network disconnected (simulación)');audience=audience==='auto'?'codes':audience;seq++;
  if(seq>1){const target=data[(seq-2)%4];target.counts[seq%target.counts.length]+=1+(seq%3);target.at=new Date().toISOString();}
  const now=new Date().toISOString();return{schema:'pulso-live-1',audience,private:audience!=='released',can_internal:true,server_time:now,valid_until:new Date(Date.now()+15000).toISOString(),poll_ms:5000,timezone:'America/Asuncion',election_date:'2026-10-04',
   cities:data.map((x,i)=>{const base=x.counts.reduce((a,b)=>a+b,0),accepted=base+Object.values(x.other).reduce((a,b)=>a+b,0);return{id:x.id,city:x.name,city_code:x.code,state:'live',questionnaire_version:1,alias_version:1,
    counts:audience==='released'?{candidate_base:base}:{candidate_base:base,accepted,received:accepted+x.pending+x.excluded,pending_review:x.pending,excluded:x.excluded},
    candidates:x.counts.map((count,j)=>({code:x.code+'-'+String.fromCharCode(65+j),count,...(audience==='internal'?{real_name:'Candidatura FICTICIA '+String.fromCharCode(65+j),list:'Lista DEMO '+(j+1)}:{})})),
    last_received:x.at,coverage:{represented_points:2+i,configured_points:3+i},other_answers:audience==='released'?null:{...x.other}};}),
   base_definition:'Base de candidaturas de cada ciudad; respuestas sintéticas.',limitations:'DEMO: todos los conteos son ficticios, no representan a candidaturas reales.'};};
 return {load,setOffline:value=>offline=value};
}
