'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const C=require('../web/core.js');
const NOW=Date.parse('2026-10-04T13:00:00Z');
const meta=C.makeDemo(NOW),p=meta.profiles[0];
function event(extra={}){return {id:'00000000-0000-4000-8000-000000000001',district_id:p.district_id,agent_id:p.id,station_id:p.station_id,outcome:'candidate',candidate_id:'cde-c1',already_voted:true,consent:true,started_at:'2026-10-04T12:59:30Z',captured_at:'2026-10-04T13:00:00Z',received_at:'2026-10-04T13:05:00Z',geo_status:'not_requested',latitude:null,longitude:null,accuracy_m:null,geo_captured_at:null,...extra};}
test('four independent districts',()=>assert.equal(C.DISTRICTS.length,4));
test('60 interviewer profiles, exactly 15 in each district',()=>{assert.equal(meta.profiles.length,60);for(const d of C.DISTRICTS)assert.equal(meta.profiles.filter(p=>p.district_id===d.id).length,15);});
test('all staff codes are unique',()=>assert.equal(new Set(meta.profiles.map(p=>p.code)).size,60));
test('catalogue has 12 supplied names with exact labels',()=>{assert.equal(meta.candidates.length,12);assert.equal(meta.candidates.find(c=>c.name==='José Castillo').list_label,'Lista 2026');assert.equal(meta.candidates.find(c=>c.name==='Roberto Almiron').list_label,'Lista 6');assert.equal(meta.candidates.find(c=>c.name==='Oscar “Melli” González').list_label,'Lista 1');});
test('catalogue sizes are 2/4/2/4 by application district order',()=>assert.deepEqual(C.DISTRICTS.map(d=>meta.candidates.filter(c=>c.district_id===d.id).length),[2,4,2,4]));
test('no synthetic observations preloaded against real names',()=>assert.equal(meta.records.length,0));
test('no invented official polling locations',()=>assert.ok(meta.stations.every(s=>s.is_template&&s.name.includes('NO OFICIAL'))));
test('election date fixed to October 4',()=>assert.equal(meta.settings.fieldwork_date,'2026-10-04'));
test('zero denominator is finite',()=>assert.equal(C.pct(0,0),0));
test('valid consented capture',()=>assert.equal(C.validateCapture(event(),p,meta.candidates),true));
for(const [name,overrides] of [
 ['must already have voted',{already_voted:false}],['must consent',{consent:false}],['no foreign city candidate',{candidate_id:'minga-c1'}],['no foreign station',{station_id:'minga-p1'}],['blank cannot contain candidate',{outcome:'blank'}],['refusal cannot disclose a preference',{outcome:'refused',consent:false}],['refusal cannot include consent',{outcome:'refused',candidate_id:null}],['invalid timestamp',{captured_at:'bad'}],['missing start timestamp',{started_at:null}],['invalid start timestamp',{started_at:'bad'}],['negative duration',{started_at:'2026-10-04T13:01:00Z'}],['overlong duration',{started_at:'2026-10-04T09:00:00Z'}],['unknown geolocation status',{geo_status:'tracked'}],['coordinates without permission',{latitude:0,longitude:0}],['GPS missing fields',{geo_status:'granted'}],
])test(name,()=>assert.throws(()=>C.validateCapture(event(overrides),p,meta.candidates)));
test('anonymous refusal contains no preference',()=>assert.ok(C.validateCapture(event({outcome:'refused',candidate_id:null,consent:false}),p,meta.candidates)));
for(const role of ['viewer','admin'])test(role+' cannot submit',()=>assert.throws(()=>C.validateCapture(event(),{...p,role},meta.candidates)));
test('disabled interviewer cannot submit',()=>assert.throws(()=>C.validateCapture(event(),{...p,active:false},meta.candidates)));
const geo={geo_status:'granted',latitude:-25.5,longitude:-54.6,accuracy_m:15,geo_captured_at:'2026-10-04T12:59:59Z'};
test('valid one-time staff GPS',()=>assert.ok(C.validateCapture(event(geo),p,meta.candidates)));
for(const [name,g] of [['invalid latitude',{latitude:91}],['invalid longitude',{longitude:181}],['negative accuracy',{accuracy_m:-1}],['stale GPS',{geo_captured_at:'2026-10-04T12:00:00Z'}],['future GPS',{geo_captured_at:'2026-10-04T13:10:00Z'}]])test(name,()=>assert.throws(()=>C.validateCapture(event({...geo,...g}),p,meta.candidates)));
const sample=[event(),event({id:'2',candidate_id:'cde-c2'}),event({id:'3',outcome:'blank',candidate_id:null}),event({id:'4',outcome:'refused',candidate_id:null,consent:false}),event({id:'5',voided_at:'2026-10-04T13:10:00Z'})];
test('denominators separate nonresponse/blank and omit voided rows',()=>{const d=C.summarize(meta,sample,NOW).districts[0];assert.equal(d.total,4);assert.equal(d.valid,2);assert.equal(d.answered,3);assert.equal(d.blank,1);assert.equal(d.refused,1);assert.deepEqual(d.candidates.map(c=>c.count),[1,1]);});
test('station selection excludes all unrelated districts and operators',()=>{const snap=C.summarize(meta,sample,NOW,{station_id:'cde-p1'});assert.equal(snap.districts.length,1);assert.equal(snap.districts[0].stations.length,1);assert.equal(snap.districts[0].agents.length,5);assert.equal(snap.districts[0].agents[0].count,4);});
test('per-location and per-interviewer quantities agree',()=>{const d=C.summarize(meta,sample,NOW).districts[0];assert.equal(d.stations.reduce((n,s)=>n+s.count,0),d.total);assert.equal(d.agents.reduce((n,a)=>n+a.count,0),d.total);});
test('capture and receipt timestamps remain different',()=>{const r=event({received_at:'2026-10-04T15:05:00Z'}),d=C.summarize(meta,[r],NOW).districts[0];assert.equal(d.capture_hours[0].hour,'2026-10-04T13:00:00.000Z');assert.equal(d.hours[0].hour,'2026-10-04T15:00:00.000Z');assert.equal(d.agents[0].last_captured,r.captured_at);assert.equal(d.agents[0].last_received,r.received_at);});
test('candidate order is catalogue order, never a winner ordering',()=>{const d=C.summarize(meta,[event({candidate_id:'cde-c2'})],NOW).districts[0];assert.equal(d.candidates[0].name,'Rigo Chamorro');});
test('CSV injection protection',()=>{const t=C.csv([['=HYPERLINK("x")','  +cmd','plain']]);assert.ok(t.includes("'=HYPERLINK"));assert.ok(t.includes("'  +cmd"));});
test('HTML escaping',()=>assert.equal(C.esc('<img onerror="x">'), '&lt;img onerror=&quot;x&quot;&gt;'));
test('exports identify sample limitations',()=>assert.match(C.aggregateCsv(C.summarize(meta,sample,NOW),'PRACTICA_NO_REAL'),/Muestra no ponderada/));
