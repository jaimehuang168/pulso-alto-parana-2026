// SERVER ONLY. Deploy to Supabase Edge Functions, never to web/.
// Gateway verify_jwt=false is safe here ONLY because every call validates
// the user's access token with Auth and then checks the DB-owned admin role.
import { createClient } from 'npm:@supabase/supabase-js@2.116.0';
const URL = Deno.env.get('SUPABASE_URL') || '';
const SECRET = Deno.env.get('PULSO_SUPABASE_SECRET_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const ORIGINS = (Deno.env.get('APP_ORIGIN') || '').split(',').map(v=>v.trim()).filter(Boolean);
const PREFIX: Record<string,string> = {cde:'CDE',minga:'MGA',hernandarias:'HER',franco:'PFR'};
const NAMES: Record<string,string> = {cde:'Ciudad del Este',minga:'Minga Guazú',hernandarias:'Hernandarias',franco:'Presidente Franco'};
function password(): string {const bytes=crypto.getRandomValues(new Uint8Array(24));return btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');}
Deno.serve(async(req: Request)=>{
  const origin=req.headers.get('Origin')||'';
  const cors: Record<string,string> = {'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
  if(origin&&ORIGINS.includes(origin))cors['Access-Control-Allow-Origin']=origin;
  const reply=(body: unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
  if(origin&&!ORIGINS.includes(origin))return reply({error:'Origen no permitido. Configure APP_ORIGIN.'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
  if(req.method!=='POST')return reply({error:'Método no permitido.'},405);
  if(!URL||!SECRET)return reply({error:'Falta configuración segura de servidor.'},500);
  const auth=req.headers.get('Authorization')||'';
  if(!auth.startsWith('Bearer '))return reply({error:'Se requiere inicio de sesión.'},401);
  const admin=createClient(URL,SECRET,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
  try {
  const {data:verified,error:authError}=await admin.auth.getUser(auth.slice(7));
  if(authError||!verified.user)return reply({error:'Sesión no válida.'},401);
  const {data:actor,error:actorError}=await admin.from('profiles').select('id,role,active').eq('id',verified.user.id).single();
  if(actorError||!actor?.active||actor.role!=='admin')return reply({error:'Solo coordinación autorizada.'},403);
  const {data:mode,error:modeError}=await admin.from('settings').select('*').eq('id',1).single();
  if(modeError||mode?.operation_mode==='v3')return reply({error:'Use la administración V3. El servicio V2 ya no está habilitado.'},409);
  let body: {action?:string;district_id?:string;code?:string;role?:string;display_name?:string};
  try{const raw=await req.text();if(raw.length>4096)return reply({error:'Solicitud demasiado grande.'},413);body=JSON.parse(raw);}catch{return reply({error:'JSON inválido.'},400);}
  if(body.action==='reset-password'){
    if(!/^((CDE|MGA|HER|PFR)-(0[1-9]|1[0-5])|(VIEW|ADMIN)-[A-Z0-9]{3,12}|COORD-01)$/.test(body.code||''))return reply({error:'Código inválido.'},400);
    const {data:p,error}=await admin.from('profiles').select('id,code,role,district_id,station_id').eq('code',body.code!).single();
    if(error||!p||!['interviewer','viewer','admin'].includes(p.role))return reply({error:'Cuenta no encontrada.'},404);
    if(p.id===actor.id)return reply({error:'Use Cambiar mi contraseña para su propia cuenta.'},400);
    const pw=password();
    const {error:updateError}=await admin.auth.admin.updateUserById(p.id,{password:pw});
    if(updateError)return reply({error:'No se pudo restablecer la contraseña.'},500);
    const {data:station}=await admin.from('stations').select('name').eq('id',p.station_id).single();
    await admin.from('audit_log').insert({actor_id:actor.id,action:'account_password_reset',subject_id:p.id});
    return reply({credential:{code:p.code,password:pw,role:p.role,district:NAMES[p.district_id]||'Todas las ciudades',station:station?.name||''}});
  }

  if(body.action==='create-account'){
    const role=body.role||'',code=(body.code||'').trim().toUpperCase();
    const name=(body.display_name||'').trim();
    if(!['admin','viewer'].includes(role)||name.length>100||!(role==='admin'?/^ADMIN-[A-Z0-9]{3,12}$/:/^VIEW-[A-Z0-9]{3,12}$/).test(code))return reply({error:'Rol o código inválido. Use ADMIN-xxx o VIEW-xxx según el rol.'},400);
    const district=role==='admin'?null:(body.district_id||null);
    if(district&&!PREFIX[district])return reply({error:'Ciudad inválida.'},400);
    const {data:duplicate,error:lookupError}=await admin.from('profiles').select('id').eq('code',code).maybeSingle();
    if(lookupError)return reply({error:'No se pudo comprobar la cuenta.'},500);
    if(duplicate)return reply({error:'Este código ya existe.'},409);
    const pw=password();
    const {data:created,error:createError}=await admin.auth.admin.createUser({email:code.toLowerCase()+'@pulso-encuestadores.invalid',password:pw,email_confirm:true});
    if(createError||!created.user)return reply({error:'No se creó la cuenta. Verifique duplicados en Auth.'},409);
    const {error:profileError}=await admin.from('profiles').insert({id:created.user.id,code,role,display_name:name,district_id:district,station_id:null,slot:null,active:true});
    if(profileError){await admin.auth.admin.deleteUser(created.user.id);return reply({error:'Perfil inválido. No se habilitó la cuenta.'},400);}
    const {error:auditError}=await admin.from('audit_log').insert({actor_id:actor.id,action:'access_account_created',subject_id:created.user.id,detail:{role,code,district_id:district}});
    return reply({credential:{code,password:pw,role,district:district?NAMES[district]:'Todas las ciudades',station:''},warning:auditError?'Cuenta creada; revisar auditoría.':undefined});
  }
  if(body.action!=='provision'||!body.district_id||!PREFIX[body.district_id])return reply({error:'Acción o distrito inválido.'},400);
  const d=body.district_id;
  const {data:settings,error:settingsError}=await admin.from('settings').select('state').eq('id',1).single();
  if(settingsError||settings?.state!=='setup')return reply({error:'Solo se crean cuentas antes de abrir la jornada.'},409);
  const {data:stations,error:stationsError}=await admin.from('stations').select('id,name').eq('district_id',d).eq('active',true).order('name');
  if(stationsError||!stations?.length)return reply({error:'Configure locales activos en este distrito.'},400);
  const {data:existing,error:existingError}=await admin.from('profiles').select('code').eq('district_id',d).eq('role','interviewer');
  if(existingError)return reply({error:'No se pudo consultar el equipo.'},500);
  const used=new Set((existing||[]).map(p=>p.code));
  const created: Array<{code:string;password:string;role:string;district:string;station:string}>=[];
  const skipped:string[]=[],errors:string[]=[];
  for(let slot=1;slot<=15;slot++){
    const code=PREFIX[d]+'-'+String(slot).padStart(2,'0');
    if(used.has(code)){skipped.push(code);continue;}
    const pw=password(),station=stations[(slot-1)%stations.length];
    const {data:userData,error:createError}=await admin.auth.admin.createUser({email:code.toLowerCase()+'@pulso-encuestadores.invalid',password:pw,email_confirm:true});
    if(createError||!userData.user){errors.push(code+': no creado; verifique si ya existe un usuario Auth sin perfil.');continue;}
    const id=userData.user.id;
    const {error:profileError}=await admin.from('profiles').insert({id,code,role:'interviewer',district_id:d,station_id:station.id,slot,active:true});
    if(profileError){const {error:cleanupError}=await admin.auth.admin.deleteUser(id);errors.push(code+': fallo al asignar perfil.'+(cleanupError?' Revise el usuario Auth huérfano.':''));continue;}
    created.push({code,password:pw,role:'interviewer',district:NAMES[d],station:station.name});
    const {error:auditError}=await admin.from('audit_log').insert({actor_id:actor.id,action:'interviewer_created',subject_id:id,detail:{district_id:d,code}});
    if(auditError)errors.push(code+': cuenta creada; revisar escritura de auditoría.');
  }
  // Do not console.log this payload: it contains one-time credentials.
  return reply({created,skipped,errors});
  } catch { return reply({error:'Error de servidor. Revise el estado de las cuentas antes de reintentar.'},500); }
});
