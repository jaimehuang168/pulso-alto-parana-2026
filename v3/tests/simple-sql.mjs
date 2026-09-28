/** SQL policy verification, synthetic Auth fixtures, isolated PGlite. */
import {database,as,admin,adminSession} from './db-fixture.mjs';
import fs from 'node:fs/promises';import assert from 'node:assert/strict';import{randomUUID as uuid}from'node:crypto';
const db=await database(),checks=[];
const check=async(name,f)=>{try{await f();checks.push({name,pass:true});console.log('PASS',name)}catch(e){checks.push({name,pass:false,error:e.message});throw e}};
const rpc=async(n,args=[],u=admin,s=adminSession)=>(await as(db,u,s,`select public.${n}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args))[0].r;
const service=async(step,data)=>{await db.exec('BEGIN;SET LOCAL ROLE service_role');try{const r=await db.query('select public.v3_simple_account_service($1,$2) r',[step,data]);await db.exec('COMMIT');return r.rows[0].r}catch(e){await db.exec('ROLLBACK');throw e}};
const args=()=>({actor_id:admin,session_id:adminSession,request_id:uuid(),code:'ENC-'+uuid().slice(0,8).toUpperCase(),display_name:'Persona de ensayo',district_id:'cde',point_id:null});
let w,ws,person;
try{
 for(const f of ['009_v3_reports.sql','010_v3_live_board.sql','011_v3_live_console.sql','012_v3_company_admin.sql','013_v3_company_handoff.sql'])await db.exec(await fs.readFile(new URL('../../supabase/migrations/'+f,import.meta.url),'utf8'));
 await db.query("insert into pulso_v3.super_admins(user_id,authorization_reference) values($1,'Isolated owner fixture, not production')",[admin]);
 await db.exec(await fs.readFile(new URL('../../supabase/migrations/014_v3_direct_use.sql',import.meta.url),'utf8'));
 const sql=await fs.readFile(new URL('../../supabase/migrations/015_v3_simple_interviewers.sql',import.meta.url),'utf8');
 const before=(await db.query('select * from pulso_v3.operations')).rows;
 await check('015 installs without changing operation or inserting answers',async()=>{await db.exec(sql);assert.deepEqual((await db.query('select * from pulso_v3.operations')).rows,before);assert.equal((await db.query('select count(*)::int n from pulso_v3.responses')).rows[0].n,0)});
 await check('Repeat 015 is safe',async()=>{await db.exec(sql);assert.equal((await db.query('select count(*)::int n from pulso_v3.schema_versions where version=15')).rows[0].n,1)});
 await check('Bootstrap includes server-issued mode, retains actual role',async()=>{const b=await rpc('v3_bootstrap');assert.equal(b.simple_login_version,15);assert.equal(b.actor.role,'admin')});
 let input=args(),reservation;
 await check('Admin reserves one individual account without password fields',async()=>{reservation=await service('prepare',input);assert(reservation.person_id);assert.equal(reservation.state,'prepared');assert(!JSON.stringify(reservation).includes('password'))});
 await check('Same request preserves person identity',async()=>assert.equal((await service('prepare',input)).person_id,reservation.person_id));
 await check('Changing payload under same request is rejected',()=>assert.rejects(service('prepare',{...input,display_name:'Another person'}),/IDEMPOTENCY_CONFLICT/));
 await check('A different request cannot reuse reserved code',()=>assert.rejects(service('prepare',{...input,request_id:uuid()}),/CODE_EXISTS/));
 await check('Role injection and password fields are rejected in database service',async()=>{for(const k of ['role','is_super_admin','password'])await assert.rejects(service('prepare',{...args(),[k]:'admin'}),/INVALID_REQUEST/)});
 await check('Null code and false city rejected',async()=>{await assert.rejects(service('prepare',{...args(),code:null}),/INVALID_INTERVIEWER/);await assert.rejects(service('prepare',{...args(),district_id:'not-city'}),/INVALID_INTERVIEWER/)});
 w=uuid();ws=uuid();person=reservation.person_id;
 await check('Mismatching Auth identity cannot complete reservation',()=>assert.rejects(service('complete',{...input,auth_user_id:uuid()}),/AUTH_ID_MISMATCH/));
 await db.query('insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values($1,$2,now(),$3)',[w,reservation.email,{pulso_simple_request:input.request_id,pulso_simple_creator:admin,pulso_simple_person:person}]);
 await db.query('insert into auth.sessions values($1,$2)',[ws,w]);
 await check('Exact server-marked Auth identity completes with interviewer role only',async()=>{const d=await service('complete',{...input,auth_user_id:w});assert(d.completed);assert.equal(d.role,'interviewer');assert.equal((await rpc('v3_bootstrap',[],w,ws)).actor.user_id,w)});
 await check('No training date or practice completion was fabricated',async()=>{const p=(await db.query('select * from pulso_v3.people where id=$1',[person])).rows[0];assert.equal(p.training_passed_at,null);assert.equal(p.training_practice_ack,false);assert.equal(p.approval,'approved');assert.equal(p.onboarding_mode,'admin_managed')});
 await check('Complete retry does not create another person',async()=>{assert((await service('complete',{...input,auth_user_id:w})).duplicate);assert.equal((await db.query('select count(*)::int n from pulso_v3.people where id=$1',[person])).rows[0].n,1)});
 await check('Interviewer cannot provision another account',()=>assert.rejects(service('prepare',{...args(),actor_id:w,session_id:ws}),/ADMIN_ONLY/));
 await check('Browser roles cannot call service directly',()=>assert.rejects(rpc('v3_simple_account_service',['prepare',args()]),/permission denied/));
 await check('Unassigned login gives waiting screen, not global questionnaire',async()=>assert.equal((await rpc('v3_prepare_interviewer',[uuid()],w,ws)).status,'waiting_assignment'));
 await check('Admin cannot impersonate fieldwork with ready endpoint',()=>assert.rejects(rpc('v3_prepare_interviewer',[uuid()]),/WORKER_ONLY/));
 await check('Foreign point ID rejected before creating any profile',()=>assert.rejects(service('prepare',{...args(),point_id:uuid()}),/POINT_DISTRICT_MISMATCH/));
 await check('Suspended account cannot obtain new authorization',async()=>{await db.query("update pulso_v3.people set approval='suspended' where id=$1",[person]);assert.equal((await rpc('v3_prepare_interviewer',[uuid()],w,ws)).status,'waiting_admin')});
 await check('No false activation or synthetic vote inserted',async()=>{assert.deepEqual((await db.query('select * from pulso_v3.operations')).rows,before);assert.equal((await db.query('select count(*)::int n from pulso_v3.responses')).rows[0].n,0)});
}catch(e){console.error(e);if(!checks.some(x=>!x.pass))checks.push({name:'SQL fixture setup',pass:false,error:e.message});process.exitCode=1}
finally{await fs.mkdir(new URL('../evidence',import.meta.url),{recursive:true});await fs.writeFile(new URL('../evidence/simple-sql.json',import.meta.url),JSON.stringify({scope:'Isolated PGlite, synthetic accounts, no production',passed:checks.filter(x=>x.pass).length,failed:checks.filter(x=>!x.pass).length,checks},null,2));await db.close();}
