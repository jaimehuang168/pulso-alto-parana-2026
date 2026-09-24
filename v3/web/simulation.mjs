/** Isolated browser SQL simulation. Never imported when simulation=false. No production requests. */
import {PGlite} from '@electric-sql/pglite';
import {CLIENT,uuid,digest,token,CITIES} from './modules/core.mjs';
const ADMIN='11111111-1111-4111-8111-111111111111',SESSION='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
export async function createSimulation(){
 const db=new PGlite();await db.exec(await(await fetch('simulation-install.sql')).text());let user=ADMIN,session=SESSION;let serial=Promise.resolve();const peopleAccounts=[];
 const locked=fn=>{const next=serial.then(fn);serial=next.catch(()=>{});return next;};
 const as=async(u,s,fn)=>{await db.exec('BEGIN;SET LOCAL ROLE authenticated;');try{await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:u,session_id:s,role:'authenticated'})]);const v=await fn();await db.exec('COMMIT');return v;}catch(e){await db.exec('ROLLBACK');throw e;}};
 const call=async(name,args={})=>{if(!/^v3_[a-z_]+$/.test(name)||Object.keys(args).some(x=>!/^p_[a-z_]+$/.test(x)))throw new Error('V3_INVALID_RPC');return as(user,session,async()=>Object.values((await db.query(`select public.${name}(${Object.keys(args).map((k,i)=>k+'=> $'+(i+1)).join(',')})`,Object.values(args))).rows[0])[0]);};
 const command=(a,d,r=0)=>call('v3_command',{p_action:a,p_data:d,p_request_id:uuid(),p_expected:r});
 const today=(await db.query("select (now() at time zone 'America/Asuncion')::date::text as day")).rows[0].day;
 await command('operation.save',{title:'SIMULACIÓN · Pulso V3',contest:'Intendencia municipal',fieldwork_date:today,retention_policy:'Datos sintéticos; se descartan al recargar.'},1);
 await call('v3_activate',{p_legacy_outbox_handled:true,p_backup_reference:'Simulación aislada sin base externa',p_acceptance_reference:'Aceptación simulada no válida para producción'});
 for(const [idx,d]of CITIES.entries()){
  const site=(await command('station.save',{district_id:d.id,code:'DEMO-'+d.code,name:'Centro DEMO '+d.code,address:'Dirección sintética para demostración'})).id;
  const point=(await command('point.save',{station_id:site,code:'DEMO-PT-'+d.code,label:'Acceso DEMO '+d.code})).id;
  await command('point.approve',{id:point,verified:true,reason:'Autorización sintética del simulador'},1);
  const q=(await command('questionnaire.save',{district_id:d.id,contest:'Intendencia municipal',methodology:'Práctica: cada quinto elector, participación voluntaria y registro de rechazo.',sample_interval:5,reference:'Referencia ficticia del simulador',items:[{id:uuid(),name:'Candidatura DEMO A',list:'Lista DEMO A'},{id:uuid(),name:'Candidatura DEMO B',list:'Lista DEMO B'}]})).id;
  await command('questionnaire.publish',{id:q,confirmed:true},1);
  const person=(await command('person.add',{district_id:d.id,point_id:point,display_name:'Encuestador DEMO '+d.code})).id;const u=uuid(),ss=uuid();
  await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[u,'demo-'+d.code.toLowerCase()+'@example.invalid']);await db.query('insert into auth.sessions values($1,$2)',[ss,u]);
  const w=(await db.query('select code from pulso_v3.people where id=$1',[person])).rows[0];await db.query("insert into pulso_v3.actors(user_id,person_id,code,display_name,role,enrolled) values($1,$2,$3,$4,'interviewer',true)",[u,person,w.code,'Encuestador DEMO '+d.code]);
  const actor=user,oldSession=session;user=u;session=ss;await call('v3_training',{p_answers:['after_voting','voluntary','pending_not_received'],p_practice_ack:true});user=actor;session=oldSession;
  await command('person.approve',{id:person,reason:'Práctica aprobada en simulador'},2);
  const task=(await command('assignment.create',{person_id:person,point_id:point,reason:'Tarea sintética inicial'})).id;user=u;session=ss;await call('v3_ack_assignment',{p_assignment:task,p_version:1,p_questionnaire:q,p_point:point});user=actor;session=oldSession;
  peopleAccounts.push({id:u,session:ss,point,person,task,label:'Encuestador '+d.code,code:w.code});
 }
 const revision=(await db.query('select revision from pulso_v3.operations')).rows[0].revision;await command('operation.state',{state:'running',reason:'Inicio de simulación local'},revision);
 for(const a of peopleAccounts)await command('point.state',{id:a.point,state:'open',reason:'Punto de demostración'},2);
 const co=uuid(),cs=uuid(),viewer=uuid(),vs=uuid();for(const [u,s,c,r]of [[co,cs,'COORD-DEMO','coordinator'],[viewer,vs,'VIEW-DEMO','viewer']]){await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[u,c.toLowerCase()+'@example.invalid']);await db.query('insert into auth.sessions values($1,$2)',[s,u]);await db.query('insert into pulso_v3.actors(user_id,code,display_name,role,enrolled) values($1,$2,$2,$3,true)',[u,c,r]);}
 await command('grant.save',{user_id:co,district_id:'cde',capabilities:['operations','recruit','assign','manage_points','control_points'],valid_until:new Date(Date.now()+86400000).toISOString()});
 await command('grant.save',{user_id:viewer,district_id:'cde',capabilities:['view_results'],valid_until:new Date(Date.now()+86400000).toISOString()});
 const accounts=[{id:ADMIN,session:SESSION,label:'Administrador',code:'COORD-01'},{id:co,session:cs,label:'Coordinador CDE',code:'COORD-DEMO'},{id:viewer,session:vs,label:'Viewer CDE',code:'VIEW-DEMO'},...peopleAccounts];
 const enrollmentTokens=new Map();const api={accounts,simulation:true,
  session:async()=>null,
  async demoLogin(id){const a=accounts.find(a=>a.id===id);if(!a)throw new Error('V3_ACCOUNT_DISABLED');user=a.id;session=a.session;return {user:{id:user},access_token:'SIMULATION_NO_TOKEN'};},
  async login(code){const a=accounts.find(a=>a.code.toLowerCase()===code.toLowerCase());if(!a)throw new Error('invalid_credentials');return this.demoLogin(a.id);},
  rpc:(name,args={})=>locked(()=>call(name,args)),command:(a,d,e=0,r=uuid())=>locked(()=>call('v3_command',{p_action:a,p_data:d,p_expected:e,p_request_id:r,p_client:CLIENT})),
  async logout(){user=ADMIN;session=SESSION;},async connect(){},async changePassword(){throw new Error('V3_SIMULATION_NO_AUTH_PASSWORD');},
  async edge(body){return locked(async()=>{if(body.action==='issue'){const tk=token();const r=(await db.query("select public.v3_enrollment_service('issue',$1) r",[{actor_id:user,session_id:session,person_id:body.person_id,point_id:body.point_id,request_id:body.request_id,token_hash:await digest(tk)}])).rows[0].r;enrollmentTokens.set(tk,r);return {...r,token:tk};}if(body.action==='revoke')return (await db.query("select public.v3_enrollment_service('revoke',$1) r",[{actor_id:user,session_id:session,id:body.id}])).rows[0].r;throw new Error('V3_SIMULATION_AUTH_REQUIRES_STAGING');});},
  async claim(){throw new Error('V3_SIMULATION_AUTH_REQUIRES_STAGING');},async attachmentUpload(){throw new Error('V3_SIMULATION_STORAGE_REQUIRES_STAGING');},async attachmentURL(){throw new Error('V3_SIMULATION_STORAGE_REQUIRES_STAGING');}
 };return api;
}
