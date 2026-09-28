// Server-only account provisioning. No database password/API secret is sent to browsers.
import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
const url=Deno.env.get('SUPABASE_URL')||'';
const secret=Deno.env.get('PULSO_SUPABASE_SECRET_KEY')||Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const origins=(Deno.env.get('PULSO_V3_ORIGINS')||Deno.env.get('APP_ORIGIN')||'').split(',').map(s=>s.trim()).filter(Boolean);
const uuid=(v:unknown):v is string=>typeof v==='string'&&/^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i.test(v);
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'';
 const headers:Record<string,string>={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Referrer-Policy':'no-referrer',
  'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
 if(origins.includes(origin))headers['Access-Control-Allow-Origin']=origin;
 const reference=crypto.randomUUID();const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(!origin||!origins.includes(origin))return reply({error:'V3_ORIGIN_DENIED',reference},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({error:'V3_POST_REQUIRED',reference},405);
 if(!url||!secret||secret.startsWith('sb_publishable_'))return reply({error:'V3_SERVER_KEY_CONFIGURATION',reference},503);
 try{
  const bearer=req.headers.get('authorization')||'';if(!bearer.startsWith('Bearer '))return reply({error:'V3_SESSION_REQUIRED',reference},401);
  const service=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
  const {data:auth,error:bad}=await service.auth.getUser(bearer.slice(7));
  if(bad||!auth.user)return reply({error:'V3_SESSION_REQUIRED',reference},401);
  const claims=JSON.parse(atob(bearer.slice(7).split('.')[1].replaceAll('-','+').replaceAll('_','/')));
  if(!uuid(claims.session_id))return reply({error:'V3_SESSION_REQUIRED',reference},401);
  const raw=await req.text();if(raw.length>8192)return reply({error:'V3_REQUEST_TOO_LARGE',reference},413);
  const body=JSON.parse(raw);
  if(!body||Array.isArray(body)||typeof body!=='object'||body.action!=='create_interviewer'
    ||Object.keys(body).some(k=>!['action','request_id','code','display_name','district_id','point_id','password'].includes(k))
    ||!uuid(body.request_id)||typeof body.password!=='string'||body.password.length<16||body.password.length>128
    ||/[\u0000-\u001f\u007f]/.test(body.password))return reply({error:'V3_INVALID_INTERVIEWER',reference},400);
  const bucket=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(auth.user.id))),x=>x.toString(16).padStart(2,'0')).join('');
  const budget=await service.rpc('v3_request_budget',{p_kind:'admin',p_bucket:bucket});
  if(budget.error)throw budget.error;if(!budget.data)throw Error('V3_RATE_LIMIT');
  const args={actor_id:auth.user.id,session_id:claims.session_id,request_id:body.request_id,code:body.code,
    display_name:body.display_name,district_id:body.district_id,point_id:body.point_id||null};
  const call=async(step:string,extra:Record<string,unknown>={})=>{
   const r=await service.rpc('v3_simple_account_service',{p_step:step,p_data:{...args,...extra}});
   if(r.error)throw r.error;return r.data;
  };
  let state=await call('prepare');
  if(state.state==='completed')return reply({completed:true,code:state.code,credentials_unavailable:true,reference});
  let id=state.auth_user_id;let newPassword:string|undefined;
  if(!id){
   const made=await service.auth.admin.createUser({email:state.email,password:body.password,email_confirm:true,
    app_metadata:{pulso_simple_request:body.request_id,pulso_simple_creator:auth.user.id,pulso_simple_person:state.person_id}});
   if(made.error){
    state=await call('prepare');id=state.auth_user_id;
    if(!id)throw Error('V3_AUTH_PROVISION_FAILED');
   }else{id=made.data.user.id;newPassword=body.password;}
  }
  const done=await call('complete',{auth_user_id:id});
  return reply({...done,...(newPassword?{credential:{code:state.code,password:newPassword}}:{credentials_unavailable:true}),reference});
 }catch(e){
  const message=typeof e==='object'&&e!==null&&'message'in e?String(e.message):'';
  const code=message.match(/V3_[A-Z0-9_]+/)?.[0]||'V3_SERVER_ERROR';
  console.warn(JSON.stringify({event:'simple_account_error',code,reference}));
  return reply({error:code,reference},/RATE_LIMIT/.test(code)?429:/DENIED|ONLY|DISABLED|SCOPE/.test(code)?403:/EXISTS|CONFLICT|BUSY/.test(code)?409:/SERVER|AUTH_/.test(code)?503:400);
 }
});
