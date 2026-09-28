/** Actual local Auth + Edge + SQL; run after the legacy regression fixtures. */
import fs from 'node:fs/promises';import assert from 'node:assert/strict';import{randomUUID as uuid}from'node:crypto';import pg from'pg';import{createClient}from'@supabase/supabase-js';
const x=JSON.parse(await fs.readFile('/tmp/pulso-v3-local-context.json','utf8')),f=JSON.parse(await fs.readFile('/tmp/pulso-company-private.json','utf8'));
assert(new URL(x.url).hostname==='127.0.0.1'&&new URL(x.dbUrl).hostname==='127.0.0.1');
const db=new pg.Client({connectionString:x.dbUrl});await db.connect();const checks=[],clients=[];
const make=()=>{const c=createClient(x.url,x.key,{auth:{persistSession:false,autoRefreshToken:false}});clients.push(c);return c};
const login=async(c,cred)=>{const r=await c.auth.signInWithPassword({email:cred.code.includes('@')?cred.code:cred.code.toLowerCase()+'@pulso-encuestadores.invalid',password:cred.password});if(r.error)throw r.error;return r.data};
const rpc=async(c,n,a={})=>{const r=await c.rpc(n,a);if(r.error)throw Object.assign(Error(r.error.message),r.error);return r.data};
const cmd=(c,action,data,revision=0)=>rpc(c,'v3_command',{p_action:action,p_data:data,p_expected:revision,p_request_id:uuid()});
const edge=async(c,body,origin='http://127.0.0.1:8044')=>{const s=(await c.auth.getSession()).data.session;const r=await fetch(x.url+'/functions/v1/interviewer-access',{method:'POST',headers:{'Content-Type':'application/json',apikey:x.key,Origin:origin,...(s?{Authorization:'Bearer '+s.access_token}:{})},body:JSON.stringify(body)});const d=await r.json();if(!r.ok)throw Error(d.error||'HTTP_ERROR');return d};
const check=async(n,fun)=>{try{await fun();checks.push({name:n,pass:true});console.log('PASS',n)}catch(e){checks.push({name:n,pass:false,error:e.message});throw e}};
const root=make(),admin=make(),viewer=make();const fixtures=[];
try{
 await login(root,f.admin);await login(admin,f.company);await login(viewer,f.viewer);
 const before=(await db.query('select phase,fieldwork_date,viewer_enabled from pulso_v3.operations')).rows;
 const count=(await db.query('select count(*)::int n from pulso_v3.responses')).rows[0].n;
 await check('015 installation preserves all preceding HTTP fixture responses and operation',async()=>{await db.query(await fs.readFile(new URL('../../supabase/migrations/015_v3_simple_interviewers.sql',import.meta.url),'utf8'));await new Promise(r=>setTimeout(r,1800));assert.deepEqual((await db.query('select phase,fieldwork_date,viewer_enabled from pulso_v3.operations')).rows,before);assert.equal((await db.query('select count(*)::int n from pulso_v3.responses')).rows[0].n,count)});
 await db.query("UPDATE pulso_v3.operations SET fieldwork_date=(now() AT TIME ZONE 'America/Asuncion')::date,phase='running' WHERE id=1");
 for(const district of ['cde','minga','hernandarias','franco']){
  const q=(await cmd(admin,'questionnaire.save',{district_id:district,contest:'Intendencia municipal',sample_interval:5,methodology:'Protocolo sintético neutral para pruebas aisladas',reference:'Ensayo aislado local, no producción',items:[{id:uuid(),name:'Opción de ensayo A '+district,list:'Lista de ensayo A'},{id:uuid(),name:'Opción de ensayo B '+district,list:'Lista de ensayo B'}]})).id;
  await cmd(admin,'questionnaire.publish',{id:q,confirmed:true},1);
  const station=(await cmd(admin,'station.save',{district_id:district,code:'SIMPLE-'+district.toUpperCase(),name:'Centro de ensayo '+district,address:'Dirección sintética sector '+district})).id;
  const point=(await cmd(admin,'point.save',{station_id:station,code:'SIMPLE-P-'+district.toUpperCase(),label:'Acceso de formación',planned:true,latitude:null,longitude:null})).id;
  await cmd(admin,'point.approve',{id:point,verified:true,reason:'Sitio sintético verificado solo para prueba local'},1);
  fixtures.push({district,station,point,q});
 }
 const payload={action:'create_interviewer',request_id:uuid(),code:'ENC-HTTP-001',password:'OwnPhoneTest-Only-2026!',display_name:'Entrevistadora de ensayo',district_id:'cde',point_id:fixtures[0].point};let created;
 await check('Anonymous and Viewer cannot create interviewers',async()=>{await assert.rejects(edge(make(),payload),/SESSION_REQUIRED/);await assert.rejects(edge(viewer,payload),/ADMIN_ONLY/)});
 await check('Denied origin stops account provisioning',()=>assert.rejects(edge(admin,payload,'https://not-authorized.invalid'),/ORIGIN_DENIED/));
 await check('Role injection and short passwords refused before account creation',async()=>{await assert.rejects(edge(admin,{...payload,role:'admin'}),/INVALID_INTERVIEWER/);await assert.rejects(edge(admin,{...payload,password:'123'}),/INVALID_INTERVIEWER/)});
 await check('Wrong-city point is refused',()=>assert.rejects(edge(admin,{...payload,district_id:'minga'}),/POINT_DISTRICT_MISMATCH/));
 await check('Company admin creates worker with the chosen individual password',async()=>{created=await edge(admin,payload);assert(created.completed);assert.equal(created.credential.password,payload.password);assert.equal(created.code,payload.code)});
 const worker=make();let signed;
 await check('Worker signs in through real Auth and receives only own identity',async()=>{signed=await login(worker,{code:payload.code,password:payload.password});const b=await rpc(worker,'v3_bootstrap');assert.equal(b.actor.user_id,created.user_id);assert.equal(b.actor.role,'interviewer');assert.equal(b.simple_login_version,15);assert.equal(b.people.length,1)});
 await check('No practice completion is fabricated by creation',async()=>{const p=(await db.query('select training_passed_at,training_practice_ack,onboarding_mode from pulso_v3.people where id=$1',[created.person_id])).rows[0];assert.equal(p.training_passed_at,null);assert.equal(p.training_practice_ack,false);assert.equal(p.onboarding_mode,'admin_managed')});
 await check('Repeated request does not duplicate account or reveal previous password',async()=>{const d=await edge(admin,payload);assert(d.credentials_unavailable);assert.equal(d.credential,undefined);assert.equal((await db.query('select count(*)::int n from pulso_v3.actors where code=$1',[payload.code])).rows[0].n,1)});
 await check('Interviewer cannot create other users or promote themself',()=>assert.rejects(edge(worker,{...payload,request_id:uuid(),code:'ENC-ILLEGAL-001'}),/ADMIN_ONLY/));
 await check('Login does not open a closed point',async()=>{assert.equal((await rpc(worker,'v3_prepare_interviewer',{p_device:uuid()})).status,'waiting_point');assert.equal((await db.query('select state from pulso_v3.points where id=$1',[fixtures[0].point])).rows[0].state,'approved')});
 await cmd(admin,'point.state',{id:fixtures[0].point,state:'open',reason:'Inicio de ensayo individual local'},2);
 const device=uuid();let pack;
 await check('Prepared login automatically obtains its assigned questionnaire, no manual acknowledgement',async()=>{const d=await rpc(worker,'v3_prepare_interviewer',{p_device:device});assert.equal(d.status,'ready');pack=d.pack;assert.equal(pack.point.id,fixtures[0].point);assert.equal(pack.station.district_id,'cde')});
 await check('Automatic repeat reuses valid grant and does not extend rights unexpectedly',async()=>assert.equal((await rpc(worker,'v3_prepare_interviewer',{p_device:device})).pack.grant.id,pack.grant.id));
 await check('Another device does not take over active work',()=>assert.rejects(rpc(worker,'v3_prepare_interviewer',{p_device:uuid()}),/DEVICE_IN_USE/));
 const now=new Date().toISOString(),event={id:uuid(),assignment_id:pack.assignment.id,grant_id:pack.grant.id,questionnaire_id:pack.questionnaire.id,point_id:pack.point.id,started_at:now,captured_at:now,candidate_id:pack.questionnaire.items[0].id,outcome:'candidate',already_voted:true,consent:true,geo:{status:'not_requested'}};
 await check('No-GPS response receives a real accepted receipt',async()=>assert.equal((await rpc(worker,'v3_submit_response',{p_event:event})).disposition,'accepted'));
 await check('Retry of same response counts once',async()=>{assert((await rpc(worker,'v3_submit_response',{p_event:event})).duplicate);assert.equal((await db.query('select count(*)::int n from pulso_v3.responses where id=$1',[event.id])).rows[0].n,1)});
 await check('Changing an already submitted payload is refused',()=>assert.rejects(rpc(worker,'v3_submit_response',{p_event:{...event,candidate_id:pack.questionnaire.items[1].id}}),/IDEMPOTENCY_CONFLICT/));
 await check('Wrong consent and foreign point remain rejected',async()=>{await assert.rejects(rpc(worker,'v3_submit_response',{p_event:{...event,id:uuid(),consent:false}}),/CONSENT_REQUIRED/);await assert.rejects(rpc(worker,'v3_submit_response',{p_event:{...event,id:uuid(),point_id:fixtures[1].point}}),/ASSIGNMENT_CHANGED/)});
 await check('Future or paused work cannot be started by logging in',async()=>{await db.query("UPDATE pulso_v3.operations SET phase='paused' WHERE id=1");assert.equal((await rpc(worker,'v3_prepare_interviewer',{p_device:device})).status,'waiting_start');await db.query("UPDATE pulso_v3.operations SET phase='running' WHERE id=1")});
 await check('Same phone can reauthenticate without manual task setup',async()=>{await login(worker,{code:payload.code,password:payload.password});assert.equal((await rpc(worker,'v3_prepare_interviewer',{p_device:device})).status,'ready')});
 await check('Private tables remain inaccessible to ordinary browser roles',async()=>assert((await worker.schema('pulso_v3').from('simple_accounts').select('*')).error));
 await fs.writeFile('/tmp/pulso-simple-private.json',JSON.stringify({url:x.url,key:x.key,admin:f.company,root:f.admin,viewer:f.viewer,fixtures}),{mode:0o600});
}catch(e){console.error('Simple native failure',e.message);if(!checks.some(c=>!c.pass))checks.push({name:'Fixture setup',pass:false,error:e.message});process.exitCode=1}
finally{await fs.writeFile(new URL('../evidence/simple-native.json',import.meta.url),JSON.stringify({scope:'Actual local Auth/Edge/HTTP, synthetic data, not production',passed:checks.filter(c=>c.pass).length,failed:checks.filter(c=>!c.pass).length,checks},null,2));await db.end();for(const c of clients)await c.realtime.disconnect()}
process.exit(process.exitCode||0);
