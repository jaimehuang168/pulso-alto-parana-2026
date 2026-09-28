"""Exact, reviewable source patch. No database connection or hosting action."""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
assert "import * as Simple from './modules/simple-login.mjs'" not in (r/'v3/web/app.mjs').read_text(), 'Already patched'
def edit(path,changes):
 p=r/path;s=p.read_text()
 for old,new in changes:
  if new in s and old not in s:continue
  assert s.count(old)==(2 if old=="${p.training_passed_at?'Práctica completada':'Práctica pendiente'}" else 1),(path,old[:100],s.count(old))
  s=s.replace(old,new)
 p.write_text(s)
# Allow only the two known same-project Edge routes. Auth handling remains in CloudAPI.
edit('v3/web/modules/api.mjs',[("async edge(body,anonymous=false){", "async edge(body,anonymous=false,functionName='field-enrollment'){if(!['field-enrollment','interviewer-access'].includes(functionName))throw Error('V3_UNKNOWN_ACTION');"),
 ("this.config.supabaseUrl+'/functions/v1/field-enrollment'", "this.config.supabaseUrl+'/functions/v1/'+functionName")])
p=r/'v3/web/app.mjs';s=p.read_text()
s=s.replace("import * as W from './modules/workspace.mjs';", "import * as W from './modules/workspace.mjs';\nimport * as Simple from './modules/simple-login.mjs';\nimport {DeviceVault} from './modules/device-vault.mjs';")
s=s.replace("readinessError:null};", "readinessError:null,simple:false,simpleState:null,preparing:false};")
s=s.replace("S.unlock?V.unlock(S):S.boot?", "S.unlock?(S.simple?Simple.legacyUnlock(S,V):V.unlock(S)):S.boot?")
s=s.replace("function close(){S.modal=false;", "function close(){S.credential=null;S.backup=null;S.modal=false;")
a=s.index('async function openVault(user)');b=s.index('async function enter(session)',a)
s=s[:a]+'''const personalHint=()=>{try{return JSON.parse(localStorage.getItem('pulso-personal-current')||'null');}catch{return null;}};
async function finishPhone(){
 if(!S.boot){S.boot=await vault.read('bootstrap');if(!S.boot||S.boot.actor.user_id!==vault.user||S.boot.actor.role!=='interviewer')throw Error('V3_NO_LOCAL_TASK');}
 if(S.boot.actor.user_id!==vault.user)throw Error('V3_VAULT_WRONG_KEY');
 S.unlock=false;S.error=null;S.pack=await vault.read('pack');S.queue=await vault.entries();S.started=new Date().toISOString();S.page='capture';
 await vault.write('bootstrap',S.boot);
 localStorage.setItem('pulso-personal-current',JSON.stringify({user:vault.user,environment:environment()}));
 if(navigator.onLine){await preparePhone(true);await api.connect(()=>refresh());await sync();}
 else{S.offline=true;S.simpleState=S.pack?'ready':'offline';}
 render();
}
async function preparePhone(force=false){
 if(!S.simple||!S.boot||!vault?.key||S.preparing||!navigator.onLine)return;
 if(!force&&(S.busy||S.syncing||S.choice||document.querySelector('#capture-form [name=voted]:checked')||S.modal))return;
 S.preparing=true;const before=S.pack?.assignment.id,wasReady=S.simpleState==='ready';
 try{
  const next=await api.rpc('v3_prepare_interviewer',{p_device:device(),p_client:C.CLIENT});S.simpleState=next.status;
  if(next.status==='ready'){
   S.pack=next.pack;await vault.write('pack',S.pack);
   // Get authoritative scope/state after automatic preparation; this never changes a response.
   S.boot=await api.rpc('v3_bootstrap',{p_client:C.CLIENT});await vault.write('bootstrap',S.boot);
   if(before!==S.pack.assignment.id){S.choice=null;S.started=new Date().toISOString();}
  }else{S.pack=null;await vault.write('pack',null);}
  if(!force&&S.page==='capture'&&!S.choice&&(before!==S.pack?.assignment.id||wasReady!==(next.status==='ready')))render();
 }finally{S.preparing=false;}
}
async function openVault(user){
 vault=S.simple?new DeviceVault(environment(),user):new Vault(environment(),user);await vault.open();S.vaultExists=await vault.exists();
 if(S.simple){
  if(!S.boot){const h=personalHint();if(!h||h.user!==user||h.environment!==environment())throw Error('V3_SESSION_REQUIRED');}
  if(await vault.automaticUnlock(!!S.boot)){await finishPhone();return;}
 }
 S.unlock=true;S.error=null;render();
}
''' +s[b:]
s=s.replace("S.loginCode=S.boot.actor.code;S.error=null;", "S.loginCode=S.boot.actor.code;S.simple=Simple.hasSimple(S.boot);S.simpleState=null;S.error=null;")
# Periodic server checks retain original form state, but also renew allowed simple tasks.
s=s.replace("if(b.actor.role==='interviewer'&&vault?.key){", "if(b.actor.role==='interviewer'&&vault?.key){if(S.simple)await preparePhone();")
s=s.replace("async function logout(){", "async function logout(){")
s=s.replace("S.readiness=null;S.readinessError=null;S.registry=null;S.aliases={};S.ui=W.freshUI();S.boot=null;", "localStorage.removeItem('pulso-personal-current');S.simple=false;S.simpleState=null;S.readiness=null;S.readinessError=null;S.registry=null;S.aliases={};S.ui=W.freshUI();S.boot=null;")
# Service request does not use client-supplied roles; every new direct account is an interviewer.
s=s.replace("case 'person-new':", "case 'person-new':if(S.simple&&S.boot.actor.role==='admin'){form('Crear encuestador','simple-account-form',Simple.accountFields());break;}")
s=s.replace("case 'logout':await logout();break;", """case 'simple-generate':document.querySelector('#simple-account-form [name=password]').value=Simple.generatedPassword();break;
 case 'simple-password-toggle':{const p=document.querySelector('#simple-account-form [name=password]');p.type=p.type==='password'?'text':'password';break;}
 case 'simple-retry':await preparePhone(true);render();break;
 case 'logout':await logout();break;""")
s=s.replace("case 'vault-form':{if(!S.vaultExists", "case 'vault-form':{if(S.simple){await vault.migrateLegacy(data.phrase);await finishPhone();break;}if(!S.vaultExists")
s=s.replace("case 'access-form':", """case 'simple-account-form':{
 if(!S.simple||S.boot.actor.role!=='admin')throw Error('V3_ADMIN_ONLY');
 const result=await api.edge({action:'create_interviewer',code:data.code.toUpperCase(),display_name:data.display_name,password:data.password,district_id:data.district_id,point_id:data.point_id||null,request_id:request},false,'interviewer-access');
 formEl.querySelector('[name=password]').value='';credentials(result);await refresh();break;}
 case 'access-form':""")
s=s.replace("await sync();break;}\n case 'questionnaire-form'", "await sync();if(S.simple){await preparePhone(true);render();}break;}\n case 'questionnaire-form'")
# Keep rescue as optional exceptional support, not an onboarding password.
old="case 'rescue-export':if(!vault?.key)throw new Error('V3_VAULT_LOCKED');C.download(JSON.stringify(await vault.exportEncrypted()),'PULSO_COPIA_CIFRADA_'+new Date().toISOString().slice(0,10)+'.json','application/json');break;"
new="""case 'rescue-export':if(!vault?.key)throw new Error('V3_VAULT_LOCKED');if(S.simple){const backup=await vault.portableBackup();modal('Copia privada de emergencia',`<p>Esta clave sirve solo para recuperar la copia, no para iniciar sesión. Guárdela por separado y no la publique.</p><div class="credential">${E(backup.phrase)}</div><button data-action="simple-backup-file" class="primary">Guardar copia cifrada</button><button data-action="simple-backup-key">Guardar clave por separado</button>`);S.backup=backup;}else C.download(JSON.stringify(await vault.exportEncrypted()),'PULSO_COPIA_CIFRADA_'+new Date().toISOString().slice(0,10)+'.json','application/json');break;
 case 'simple-backup-file':if(S.backup)C.download(JSON.stringify(S.backup.data),'PULSO_COPIA_PRIVADA.json','application/json');break;
 case 'simple-backup-key':if(S.backup)C.download(S.backup.phrase,'PULSO_CLAVE_COPIA_PRIVADA.txt','text/plain');break;"""
assert old in s;s=s.replace(old,new)
s=s.replace("case 'offline-open':{let hint;", "case 'offline-open':{const h=personalHint();if(h&&h.environment===environment()){S.simple=true;S.offline=!navigator.onLine;await openVault(h.user);break;}let hint;")
s=s.replace("document.addEventListener('change',e=>{", "document.addEventListener('change',e=>{if(e.target.id==='simple-city'){Simple.updateOptions(S.boot,'city');return;}if(e.target.id==='simple-station'){Simple.updateOptions(S.boot,'station');return;}")
s=s.replace("render();if(S.join)return;", "render();if(S.join)return;if(!navigator.onLine){const h=personalHint();if(h&&h.environment===environment()){S.simple=true;S.offline=true;await openVault(h.user);return;}}")
p.write_text(s)
# Wrap existing view functions rather than rewriting their data/aggregation logic.
edit('v3/web/modules/views.mjs',[("import * as W from './workspace.mjs';", "import * as W from './workspace.mjs';\nimport * as Simple from './simple-login.mjs';"),
 ("export function ownTask(S){", "export function ownTask(S){if(S.simple)return Simple.taskInfo(S);"),
 ("export function capture(S){", "export function capture(S){if(S.simple&&(!S.pack||Date.now()>Date.parse(S.pack?.grant?.capture_until)))return Simple.waiting({...S,simpleState:S.pack?'expired':S.simpleState});")])
edit('v3/web/modules/workspace-base.mjs',[("btn('Incorporar persona','person-new','','primary')", "btn(S.simple&&S.boot.actor.role==='admin'?'Crear encuestador':'Incorporar persona','person-new','','primary')"),
 ("${p.training_passed_at?'Práctica completada':'Práctica pendiente'}", "${p.onboarding_mode==='admin_managed'?'Cuenta habilitada por administración':p.training_passed_at?'Práctica completada':'Práctica pendiente'}")])
# Structured errors contain no credentials. Do not suggest weakening RLS.
edit('v3/web/modules/core.mjs',[("const ERROR_TEXT={", "const ERROR_TEXT={\n V3_INVALID_INTERVIEWER:['Revise los datos','Use código ENC-, nombre, ciudad y contraseña individual de 16 a 128 caracteres.'],\n V3_DEVICE_STORAGE_UNAVAILABLE:['No se pudo preparar el teléfono','Conserve los datos existentes y avise al administrador. No borre el almacenamiento.'],\n V3_SIMPLE_BASELINE_REQUIRED:['Actualización técnica pendiente','La administración de la plataforma debe actualizar el servidor.'],")])
# Backend function is independent of the old enrollment function.
p=r/'supabase/config.toml';s=p.read_text()
if '[functions.interviewer-access]' not in s:s+='\n[functions.interviewer-access]\nverify_jwt = false\n'
p.write_text(s)
print('Simple-login source patch applied.')

p=r/'v3/web/app.mjs';s=p.read_text().replace("if(/V3_ACCOUNT_DISABLED|V3_SESSION_REQUIRED/.test(e.message)){vault?.lock();", "if(/V3_ACCOUNT_DISABLED|V3_SESSION_REQUIRED/.test(e.message)){localStorage.removeItem('pulso-personal-current');vault?.lock();");p.write_text(s)

p=r/'v3/web/app.mjs';s=p.read_text().replace("const b=await api.rpc('v3_bootstrap',{p_client:C.CLIENT});S.boot=b;", "let b=await api.rpc('v3_bootstrap',{p_client:C.CLIENT});S.boot=b;").replace("if(S.simple)await preparePhone();", "if(S.simple){await preparePhone();b=S.boot;}");p.write_text(s)

p=r/'v3/web/app.mjs';s=p.read_text().replace("form.elements.namedItem(k)?.type==='password'?v:v.trim()", "(['password','phrase','repeat'].includes(k)||form.elements.namedItem(k)?.type==='password')?v:v.trim()");p.write_text(s)
