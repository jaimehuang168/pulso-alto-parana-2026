/** Read-only acceptance helpers. Never submit surveys or call activation. */
export const VERSION='pruebas-1';
export const READ_RPCS=new Set(['v3_bootstrap','v3_preflight','v3_live_board','v3_live_admin_state']);
export const MANUAL=['keyboard','single_city','four_cities','orientation','return_to_app','downloads','live_write','offline_queue','role_scope'];
export function validateConfig(c){
 if(!c||c.simulation!==false||typeof c.supabaseUrl!=='string'||typeof c.publishableKey!=='string')throw Error('CONFIG_INVALID');
 const u=new URL(c.supabaseUrl);
 if(u.protocol!=='https:'||!/^[-a-z0-9]+\.supabase\.co$/.test(u.hostname)||u.username||u.password||u.port||u.pathname!=='/'||u.search||u.hash)throw Error('CONFIG_INVALID');
 const k=c.publishableKey;
 if(!/^sb_publishable_[A-Za-z0-9_-]+$/.test(k)){
  try{const p=JSON.parse(atob(k.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));if(k.split('.').length!==3||p.role!=='anon')throw Error();}catch{throw Error('PUBLIC_KEY_REQUIRED');}
 }
 return {url:u.origin,key:k,project:u.hostname.split('.')[0]};
}
export function loginEmail(code){const c=String(code||'').trim();if(!c||c.length>254)throw Error('LOGIN_REQUIRED');return c.includes('@')?c:c.toLowerCase()+'@pulso-encuestadores.invalid';}
export function permittedRpc(name){if(!READ_RPCS.has(name))throw Error('WRITE_NOT_ALLOWED');return name;}
export function summarizePreflight(p){
 if(!p||!['v2','v3'].includes(p.operation_mode)||!Array.isArray(p.migrations)||!p.migrations.every(Number.isInteger)||!['legacy_responses','v3_responses','legacy_actor_drift'].every(k=>Number.isSafeInteger(p[k])&&p[k]>=0))throw Error('RESPONSE_INVALID');
 return {operation_mode:p.operation_mode,migrations:p.migrations.slice(),legacy_responses:p.legacy_responses,v3_responses:p.v3_responses,legacy_actor_drift:p.legacy_actor_drift};
}
export function summarizeBoard(b){
 if(!b||!Array.isArray(b.cities)||b.cities.length>4)throw Error('RESPONSE_INVALID');
 return {cities_returned:b.cities.length,audience:['internal','codes','released'].includes(b.audience)?b.audience:'unavailable',contains_private_labels:b.cities.some(c=>(c.candidates||[]).some(x=>x.real_name||x.name||x.list))};
}
export function allowedError(e){
 const s=String(e?.code||''),message=String(e?.message||'');
 if(/^(?:V3_[A-Z0-9_]+|PGRST\d{3}|42501|invalid_credentials|over_request_rate_limit)$/.test(s))return s;
 const v=message.match(/\bV3_[A-Z0-9_]+\b/);return v?v[0]:'REQUEST_FAILED';
}
export function safeCheck(id,status,detail,ms=0){
 if(!/^[a-z0-9_.-]{1,70}$/.test(id)||!['pass','fail','blocked','untested'].includes(status))throw Error('CHECK_INVALID');
 return {id,status,detail:String(detail||'').slice(0,240),duration_ms:Math.max(0,Math.round(ms))};
}
export function verdict(checks){return checks.some(c=>c.status==='fail')?'FALLA_REVISAR':checks.some(c=>c.status==='blocked')?'PARCIAL_REQUIERE_REVISION':checks.some(c=>c.status==='pass')?'LECTURA_VERIFICADA_NO_ES_APROBACION_FINAL':'SIN_EJECUTAR';}
export function record(checks,manual,device,physical){
 return {schema:'pulso-pruebas-1',at:new Date().toISOString(),scope:'Read-only diagnostics with actual operator login. No survey insertion, activation, backup or billing mutation.',result:verdict(checks),checks:checks.map(c=>safeCheck(c.id,c.status,c.detail,c.duration_ms)),manual:MANUAL.map(id=>({id,result:['pass','fail','not_applicable'].includes(manual[id])?manual[id]:'untested'})),device:{width:device.width,height:device.height,pixel_ratio:device.pixel_ratio,secure:device.secure,touch:device.touch},physical_device_reported_by_operator:physical===true,automated_physical_certification:false,survey_write_test_completed_by_this_page:false,production_activation_approved:false};
}
