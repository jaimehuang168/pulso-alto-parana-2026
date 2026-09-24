/** Local native integration; registration readiness is distinct from WebSocket connection. */
import fs from 'node:fs/promises';import assert from 'node:assert/strict';
export async function verifyRealtime({admin,worker,service,db,event,rpc,evidence}){
 const facts={scope:'Disposable local backend only. No user claims, credentials or answers recorded.'};
 const permitted=await admin.from('v3_signals').select('district_id,revision');if(permitted.error)throw Object.assign(new Error(permitted.error.message),permitted.error);assert.equal(permitted.data.length,4);
 const session=(await admin.auth.getSession()).data.session;await admin.realtime.setAuth(session.access_token);
 let delivered=false,control=false;const a=admin.channel('native-v3-qa'),c=service.channel('native-v3-control');
 a.on('postgres_changes',{event:'UPDATE',schema:'public',table:'v3_signals'},()=>{delivered=true;});
 c.on('postgres_changes',{event:'UPDATE',schema:'public',table:'v3_signals'},()=>{control=true;});
 const ready=ch=>new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('Realtime subscription timeout')),20000);ch.subscribe(status=>{if(status==='SUBSCRIBED'){clearTimeout(timer);resolve();}else if(['CHANNEL_ERROR','TIMED_OUT'].includes(status)){clearTimeout(timer);reject(new Error('Realtime '+status));}});});
 const registrations=async()=> (await db.query("select count(*)::int subscriptions,count(*) filter(where claims ? 'session_id')::int sessions_in_claims,count(*) filter(where claims->>'role'='authenticated')::int authenticated_subscriptions,count(*) filter(where claims->>'role'='service_role')::int service_subscriptions,count(*) filter(where exists(select 1 from auth.sessions x where x.id::text=claims->>'session_id' and x.user_id::text=claims->>'sub'))::int existing_sessions from realtime.subscription where entity='public.v3_signals'::regclass")).rows[0];
 try{
  await Promise.all([ready(a),ready(c)]);
  // The local Realtime server registers Postgres subscriptions asynchronously.
  // Wait for actual registration before generating the event being tested.
  // This is a readiness barrier, never a replacement for event-delivery validation.
  const started=Date.now();let registered=await registrations();facts.at_socket_ready=registered;
  while((registered.authenticated_subscriptions<1||registered.service_subscriptions<1)&&Date.now()-started<30000){await new Promise(r=>setTimeout(r,250));registered=await registrations();}
  facts.subscription_counts=registered;facts.registration_ms=Date.now()-started;
  assert(registered.authenticated_subscriptions>=1&&registered.existing_sessions>=1,'Authenticated Postgres subscription must actually exist');
  assert(registered.service_subscriptions>=1,'Independent native server control must actually be registered');
  const subs=(await db.query("select claims from realtime.subscription where entity='public.v3_signals'::regclass and claims->>'role'='authenticated'")).rows;
  facts.rls_replay=[];
  for(const sub of subs){await db.query('begin');try{await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify(sub.claims)]);await db.query('set local role authenticated');facts.rls_replay.push((await db.query("select public.v3_can_read_signal('cde') permitted,(select count(*) from public.v3_signals) visible_rows")).rows[0]);}catch(e){facts.rls_replay.push({error_code:e.code||'UNKNOWN'});}finally{await db.query('rollback');}}
  const before=Number((await db.query("select revision from public.v3_signals where district_id='cde'")).rows[0].revision),sent=Date.now();
  await rpc(worker,'v3_submit_response',{p_event:event(),p_client:30000});
  facts.revision_increased=Number((await db.query("select revision from public.v3_signals where district_id='cde'")).rows[0].revision)>before;
  for(let i=0;i<60&&!delivered;i++)await new Promise(r=>setTimeout(r,250));
  facts.delivery_ms=Date.now()-sent;facts.admin_received=delivered;facts.service_control_received=control;
  facts.replication=(await db.query("select count(*) total,count(*) filter(where active) active from pg_replication_slots where plugin='wal2json'")).rows;
  assert(facts.revision_increased,'Write must increment the scoped signal');
  assert(delivered,'Must observe actual authenticated Realtime delivery, not merely SUBSCRIBED');
 }finally{await fs.writeFile(new URL('native-realtime-route.json',evidence),JSON.stringify(facts,null,2));await Promise.all([admin.removeChannel(a),service.removeChannel(c)]);}
}
