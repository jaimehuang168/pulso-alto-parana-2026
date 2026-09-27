/** Fresh disposable native Auth/Edge/PostgREST. Never links to a hosted project. */
import fs from 'node:fs/promises';import assert from 'node:assert/strict';import{randomUUID,randomBytes}from'node:crypto';import pg from'pg';import{createClient}from'@supabase/supabase-js';
const finalize=process.argv.includes('--finalize'),f='/tmp/pulso-handoff-private.json';
const status=JSON.parse(await fs.readFile(process.env.LOCAL_STATUS_FILE,'utf8'));
const url=status.API_URL,key=status.ANON_KEY,secret=status.SERVICE_ROLE_KEY,dbUrl=status.DB_URL;
if(new URL(url).hostname!=='127.0.0.1'||new URL(dbUrl).hostname!=='127.0.0.1')throw Error('DISPOSABLE_LOCALHOST_REQUIRED');
const db=new pg.Client({connectionString:dbUrl,statement_timeout:30000});await db.connect();const results=[],clients=[];
const make=(k=key)=>{const c=createClient(url,k,{auth:{persistSession:false,autoRefreshToken:false}});clients.push(c);return c;};
const service=make(secret),root=make(),company=make(),viewer=make();
const rpc=async(c,name,p={})=>{const{data,error}=await c.rpc(name,p).abortSignal(AbortSignal.timeout(20000));if(error)throw Object.assign(new Error(error.message),error);return data;};
const login=async(c,code,password)=>{const r=await c.auth.signInWithPassword({email:code.includes('@')?code:code.toLowerCase()+'@pulso-encuestadores.invalid',password});if(r.error)throw r.error;return r.data.user.id;};
const edge=async(c,p)=>{const s=(await c.auth.getSession()).data.session;const r=await fetch(url+'/functions/v1/field-enrollment',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+s.access_token,Origin:'http://127.0.0.1:8044','Content-Type':'application/json'},body:JSON.stringify(p)});const d=await r.json();if(!r.ok)throw Error(d.error||'EDGE_ERROR');return d;};
const read=c=>rpc(c,'v3_company_readiness');
const save=(c,o,b,a,rev)=>rpc(c,'v3_company_readiness_save',{p_outbox_handled:o,p_backup_reference:b,p_acceptance_reference:a,p_expected:rev,p_request_id:randomUUID()});
const activate=(c,rev,id=randomUUID())=>rpc(c,'v3_company_activate',{p_expected:rev,p_request_id:id});
async function test(name,fn){try{await fn();results.push({name,pass:true});console.log('PASS',name);}catch(e){results.push({name,pass:false,error:String(e.message).slice(0,350)});throw e;}}
try{
 if(!finalize){
  const email='owner-handoff@qa.invalid',password=randomBytes(24).toString('base64url');let owner;
  await test('Install additive modules on a fresh local database without activation',async()=>{
   for(const n of ['001_schema.sql','002_municipales_2026.sql','003_safeupdate_compatibility.sql'])await db.query(await fs.readFile(new URL('../../supabase/migrations/'+n,import.meta.url),'utf8'));
   const made=await service.auth.admin.createUser({email,password,email_confirm:true});if(made.error)throw made.error;owner=made.data.user.id;
   await db.query("insert into public.profiles(id,code,role) values($1,'COORD-01','admin')",[owner]);
   await db.query(await fs.readFile(new URL('../../supabase/V3_UPGRADE_EXISTING.sql',import.meta.url),'utf8'));
   for(const n of ['009_v3_reports.sql','010_v3_live_board.sql','011_v3_live_console.sql','012_v3_company_admin.sql'])await db.query(await fs.readFile(new URL('../../supabase/migrations/'+n,import.meta.url),'utf8'));
   await db.query("insert into pulso_v3.super_admins(user_id,authorization_reference) values($1,'Only synthetic localhost owner fixture')",[owner]);
   await db.query(await fs.readFile(new URL('../../supabase/V3_1_1_COMPANY_HANDOFF.sql',import.meta.url),'utf8'));
   await new Promise(r=>setTimeout(r,1500));assert.equal((await db.query('select operation_mode from public.settings where id=1')).rows[0].operation_mode,'v2');
  });
  await test('Owner logs in without company attestation privileges',async()=>{await login(root,email,password);assert((await rpc(root,'v3_bootstrap')).actor.is_super_admin);assert.equal((await read(root)).can_edit,false);await assert.rejects(save(root,false,'','',1),/COMPANY_ADMIN_ONLY/);});
  let companyCredential;
  await test('Owner creates separate company admin in actual Edge while preparing',async()=>{companyCredential=(await edge(root,{action:'create_access',role:'admin',code:'ADMIN-HANDOFF',display_name:'Empresa QA',request_id:randomUUID()})).credential;assert(companyCredential.password);await login(company,companyCredential.code,companyCredential.password);assert.equal((await read(company)).can_edit,true);});
  await test('Company can defer all three declarations without changing mode',async()=>{await save(company,false,'','',1);assert.equal((await read(company)).ready,false);assert.equal((await rpc(company,'v3_bootstrap')).operation_mode,'v2');});
  await test('Incomplete company draft fails explicit activation',()=>assert.rejects(activate(company,2),/CONFIRMATIONS_PENDING/));
  await test('Partial actual HTTP draft persists and is not attested by owner',async()=>{await save(company,false,'Synthetic saved backup reference','',2);const d=await read(company);assert.equal(d.backup_recorded,true);assert.equal(d.acceptance_recorded,false);assert.equal(d.updated_by_code,'ADMIN-HANDOFF');assert.equal((await read(root)).backup_reference,null);});
  await test('Viewer has no company confirmation access even before fieldwork',async()=>{const r=await edge(company,{action:'create_access',role:'viewer',code:'VIEW-HANDOFF',display_name:'Viewer QA',request_id:randomUUID()});await login(viewer,r.credential.code,r.credential.password);await assert.rejects(read(viewer),/ADMIN_ONLY/);await assert.rejects(save(viewer,true,'Forged QA evidence','Forged QA evidence',3),/COMPANY_ADMIN_ONLY/);});
  await test('Old activation and anonymous access cannot bypass company confirmation',async()=>{await assert.rejects(rpc(root,'v3_activate',{p_legacy_outbox_handled:true,p_backup_reference:'Fake owner attestation forbidden',p_acceptance_reference:'Fake owner attestation forbidden'}),/USE_COMPANY_CONFIRMATIONS/);await assert.rejects(read(make()),/permission|SESSION/i);});
  await test('Company cannot disable or reset Super Admin after delegation',async()=>{await assert.rejects(rpc(company,'v3_command',{p_action:'actor.disable',p_data:{id:owner},p_request_id:randomUUID(),p_expected:1}),/PROTECTED_ACCOUNT/);await assert.rejects(edge(company,{action:'reset_password',user_id:owner}),/PROTECTED_ACCOUNT/);});
  await fs.writeFile(f,JSON.stringify({url,key,root:{code:email,password},company:companyCredential}),{mode:0o600});
 }else{
  const fxt=JSON.parse(await fs.readFile(f,'utf8'));await login(root,fxt.root.code,fxt.root.password);await login(company,fxt.company.code,fxt.company.password);
  await test('Browser-saved company declarations are read back by real HTTP',async()=>{const d=await read(company);assert(d.ready);assert.equal(d.backup_reference,'Respaldo sintético webkit');assert.equal(d.acceptance_reference,'Aceptación sintética webkit');assert.equal(d.operation_mode,'v2');});
  await test('Stale acceptance is rejected and mode unchanged',async()=>{const d=await read(company);await assert.rejects(activate(company,d.revision-1),/RELOAD_REQUIRED/);assert.equal((await read(company)).operation_mode,'v2');});
  await test('Company alone activates with actual HTTP and retries without duplicate audit',async()=>{const d=await read(company),id=randomUUID(),r=await activate(company,d.revision,id);assert(r.active&&!r.fieldwork_open);assert.equal((await activate(company,d.revision,id)).duplicate,true);assert.equal((await read(root)).activated_by_code,'ADMIN-HANDOFF');});
  await test('Owner is not asked and cannot replace the recorded company declaration',async()=>{await assert.rejects(activate(root,1),/COMPANY_ADMIN_ONLY/);await assert.rejects(save(root,true,'Not an owner task','Not an owner task',1),/COMPANY_ADMIN_ONLY/);});
  await test('Activation does not open fieldwork, create answers, change date or release results',async()=>{const b=await rpc(root,'v3_bootstrap');assert.equal(b.operation.phase,'setup');assert.equal(b.operation.fieldwork_date,'2026-10-04');assert.equal(b.operation.viewer_enabled,false);assert.equal((await db.query('select count(*)::int n from pulso_v3.responses')).rows[0].n,0);assert.equal((await db.query("select count(*)::int n from pulso_v3.audit where action='operation.v3_activated'")).rows[0].n,1);});
 }
}catch(e){console.error('FAIL',e.message);if(!results.some(r=>!r.pass))results.push({name:'Setup or finalization',pass:false,error:e.message});process.exitCode=1;}finally{
 await fs.mkdir(new URL('../evidence/',import.meta.url),{recursive:true});await fs.writeFile(new URL('../evidence/handoff-native'+(finalize?'-final':'')+'.json',import.meta.url),JSON.stringify({scope:'Disposable native Supabase; real Auth/Edge/PostgREST; no production or physical-phone certification',passed:results.filter(r=>r.pass).length,failed:results.filter(r=>!r.pass).length,results},null,2));await db.end();for(const c of clients)await c.realtime.disconnect();
}process.exit(process.exitCode||0);
