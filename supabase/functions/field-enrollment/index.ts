// Pulso V3: server only. Never deploy this module into a public web directory.
// verify_jwt=false is limited to this endpoint because the claim route uses a one-time capability.
// Every administrative route verifies the supplied Auth session, then the DB checks role and scope.
import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
const URL=Deno.env.get('SUPABASE_URL')||'';
const SECRET=Deno.env.get('PULSO_SUPABASE_SECRET_KEY')||Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const ORIGINS=(Deno.env.get('PULSO_V3_ORIGINS')||Deno.env.get('APP_ORIGIN')||'').split(',').map(x=>x.trim()).filter(Boolean);
const random=()=>{const b=crypto.getRandomValues(new Uint8Array(32));return btoa(String.fromCharCode(...b)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');};
const sha=async(x:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(x))),x=>x.toString(16).padStart(2,'0')).join('');
const uuid=(x:unknown)=>typeof x==='string'&&/^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i.test(x);
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'';
 const headers:Record<string,string>={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Referrer-Policy':'no-referrer',
  'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
 if(ORIGINS.includes(origin))headers['Access-Control-Allow-Origin']=origin;
 const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
 if(!origin||!ORIGINS.includes(origin))return reply({error:'V3_ORIGIN_DENIED'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({error:'V3_POST_REQUIRED'},405);
 if(!URL||!SECRET||SECRET.startsWith('sb_publishable_'))return reply({error:'V3_SERVER_KEY_CONFIGURATION'},500);
 let body:Record<string,any>;try{const raw=await req.text();if(raw.length>8192)return reply({error:'V3_REQUEST_TOO_LARGE'},413);body=JSON.parse(raw);if(!body||Array.isArray(body)||typeof body!=='object')throw new Error();}catch{return reply({error:'V3_INVALID_REQUEST'},400);}
 const service=createClient(URL,SECRET,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
 const call=async(fn:string,step:string,data:unknown)=>{const {data:out,error}=await service.rpc(fn,{p_step:step,p_data:data});if(error)throw error;return out;};
 const budget=async(kind:string,key:string)=>{const {data,error}=await service.rpc('v3_request_budget',{p_kind:kind,p_bucket:await sha(key)});if(error)throw error;if(!data)throw new Error('V3_RATE_LIMIT');};
 const requestRef=crypto.randomUUID();
 try{
  if(body.action==='claim'){
   if(!/^[A-Za-z0-9_-]{43}$/.test(body.token||'')||!/^[A-Za-z0-9_-]{43}$/.test(body.claim_secret||'')||!uuid(body.lock_id))return reply({error:'V3_INVALID_CLAIM',reference:requestRef},400);
   await budget('join_ip',req.headers.get('cf-connecting-ip')||req.headers.get('x-forwarded-for')?.split(',')[0]||'unknown');
   await budget('join_token',body.token);
   const shared={token_hash:await sha(body.token),claim_hash:await sha(body.claim_secret),lock_id:body.lock_id};
   let state=await call('v3_enrollment_service','claim',shared);
   let userId=state.auth_user_id;
   if(!userId){
    const {data,error}=await service.auth.admin.createUser({email:state.email,password:random(),email_confirm:true,app_metadata:{pulso_v3_person:state.person_id}});
    if(error){
     // Retry the exact saga lookup, never take over an arbitrary existing email.
     state=await call('v3_enrollment_service','claim',shared);userId=state.auth_user_id;
     if(!userId)throw Object.assign(new Error('V3_AUTH_PROVISION_FAILED'),{code:'V3_AUTH_PROVISION_FAILED'});
    }else userId=data.user.id;
   }
   await call('v3_enrollment_service','auth_record',{...shared,auth_user_id:userId});
   await call('v3_enrollment_service','ready',shared);
   const linkState=await call('v3_enrollment_service','native_link',shared);
   const {data:link,error:linkError}=await service.auth.admin.generateLink({type:'magiclink',email:linkState.email});
   if(linkError||!link.properties?.hashed_token)throw new Error('V3_NATIVE_LINK_FAILED');
   // Native one-time token is delivered only in a no-store POST response to the unique claimant.
   return reply({enrollment_id:linkState.enrollment_id,token_hash:link.properties.hashed_token,type:'email',reference:requestRef});
  }
  const bearer=req.headers.get('authorization')||'';
  if(!bearer.startsWith('Bearer '))return reply({error:'V3_SESSION_REQUIRED'},401);
  const {data:verified,error:authError}=await service.auth.getUser(bearer.slice(7));
  if(authError||!verified.user)return reply({error:'V3_SESSION_REQUIRED'},401);
  const actorId=verified.user.id;
  const claims=JSON.parse(atob(bearer.slice(7).split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));
  const sessionId=claims.session_id;if(!uuid(sessionId))return reply({error:'V3_SESSION_REQUIRED'},401);
  await budget('admin',actorId);
  if(body.action==='issue'){
   if(!uuid(body.person_id)||!uuid(body.request_id))return reply({error:'V3_INVALID_REQUEST'},400);
   const token=random();
   const result=await call('v3_enrollment_service','issue',{actor_id:actorId,session_id:sessionId,person_id:body.person_id,point_id:body.point_id||null,request_id:body.request_id,token_hash:await sha(token)});
   return reply({...result,...(result.reissue_required?{}:{token}),reference:requestRef});
  }
  if(body.action==='revoke')return reply(await call('v3_enrollment_service','revoke',{actor_id:actorId,session_id:sessionId,id:body.id}));
  if(body.action==='create_access'){
   if(!uuid(body.request_id))return reply({error:'V3_REQUEST_ID_REQUIRED'},400);
   const args={actor_id:actorId,session_id:sessionId,request_id:body.request_id,code:body.code,role:body.role,display_name:body.display_name};
   let state=await call('v3_access_service','prepare',args);let userId=state.auth_user_id;let password:string|undefined;
   if(state.state==='completed')return reply({completed:true,code:state.code,credentials_unavailable:true,reference:requestRef});
   if(!userId){password=random();const {data,error}=await service.auth.admin.createUser({email:state.email,password,email_confirm:true,app_metadata:{pulso_v3_access_request:body.request_id}});
    if(error){state=await call('v3_access_service','prepare',args);userId=state.auth_user_id;password=undefined;if(!userId)throw new Error('V3_AUTH_PROVISION_FAILED');}else userId=data.user.id;
   }
   const done=await call('v3_access_service','complete',{...args,auth_user_id:userId});
   return reply({...done,...(password?{credential:{code:state.code,password}}:{credentials_unavailable:true}),reference:requestRef});
  }
  if(body.action==='reset_password'){
   if(!uuid(body.user_id))return reply({error:'V3_INVALID_REQUEST'},400);
   const args={actor_id:actorId,session_id:sessionId,user_id:body.user_id};const target=await call('v3_access_service','reset_check',args);const password=random();
   const {error}=await service.auth.admin.updateUserById(target.user_id,{password});if(error)throw new Error('V3_RESET_FAILED');
   await call('v3_access_service','reset_finish',args);
   return reply({credential:{code:target.code,password},reference:requestRef});
  }
  return reply({error:'V3_UNKNOWN_ACTION'},400);
 }catch(error){
  const raw=error instanceof Error?error.message:typeof error==='object'&&error!==null&&'message' in error?String(error.message):'';const code=(raw.match(/V3_[A-Z0-9_]+/)||[])[0]||'V3_SERVER_ERROR';
  const status=/RATE_LIMIT/.test(code)?429:/DENIED|ONLY|DISABLED|SCOPE/.test(code)?403:/UNAVAILABLE|CLAIMED|BUSY|CONFLICT|EXISTS/.test(code)?409:/AUTH_|NATIVE|SERVER|RESET_FAILED/.test(code)?503:400;
  console.warn(JSON.stringify({event:'pulso_v3_enrollment_error',code,reference:requestRef}));
  return reply({error:code,reference:requestRef},status);
 }
});
