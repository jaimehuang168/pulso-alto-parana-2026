"""One-time, reviewable source integration. No database, keys or external calls."""
from pathlib import Path
import re,json,subprocess
R=Path(__file__).resolve().parents[2]
BASE='0a37067969273a3a16aaf282dc0caf85939e012d'
paths=['v3/web/app.mjs','v3/web/modules/views.mjs','v3/web/modules/core.mjs','v3/web/modules/company.mjs','v3/web/modules/company-readiness.mjs','v3/web/index.html','v3/scripts/build.mjs','v3/tests/company-ui.test.mjs','v3/tests/company-handoff-ui.test.mjs','v3/tests/company-browser.py','v3/tests/company-native-browser.py','v3/tests/live-native-browser.py','v3/direct/browser.py']
for name in paths:
 original=subprocess.check_output(['git','show',BASE+':'+name],cwd=R)
 if (R/name).read_bytes()!=original:raise RuntimeError('Source differs from reviewed baseline: '+name)
p=R/'v3/web/modules/core.mjs';s=p.read_text().replace("VERSION='3.1.0'","VERSION='3.1.3'").replace("admin:['overview','company'","admin:['overview','registry','company'")
s=s.replace("['Solo Super Admin','La gestión de cuentas administrativas está reservada al propietario.']","['Acceso restringido','Esta cuenta no tiene permiso para gestionar administradores.']").replace('el Super Admin','la administración').replace('El Super Admin','La administración').replace('Super Admin','administración de la plataforma');p.write_text(s)
p=R/'v3/web/modules/views.mjs';s="import * as W from './workspace.mjs';\n"+p.read_text()
s=re.sub(r'^export function shell\(S,body\)\{.*?\}\n',"export function shell(S,body){return W.shell(S,body,{notice,footer});}\n",s,flags=re.M)
s=re.sub(r'^export const footer=.*?;\n','export const footer=()=>`<footer class="footer">Encuesta anónima y voluntaria · Muestra no oficial · Hora de Asunción</footer>`;\n',s,flags=re.M)
s=s.replace('Locales y puntos','Locales').replace("company:'Empresa e inicio'","company:'Empresa'").replace('export function points(S){','function legacyPoints(S){').replace('export function people(S){','function legacyPeople(S){')
s=s.replace('export function overview(S){return overviewBase(S)+pointMetrics(S);}',"export function overview(S){return W.overview(S);}\nexport function points(S){return W.pointPage(S,{namePoint});}\nexport function people(S){return W.teamPage(S,{namePoint});}")
s=s.replace("export const pageView=(S)=>({overview,company:companyPage,points,people,tasks,catalog,access,task:ownTask,capture,queue,records,review:records,results,settings,imports,exports,paper,guide}[S.page]||ownTask)(S);", """export function pageView(S){
 if(S.page==='registry')return W.registryPage(S);
 if(S.page==='tasks'||S.page==='catalog')return W.filterBar(S)+({tasks,catalog}[S.page])({...S,boot:W.filteredBoot(S)});
 if(S.page==='capture')return W.captureActivity(S)+capture(S);
 if(S.page==='review')return records(S);
 return ({overview,company:companyPage,points,people,access,task:ownTask,queue,records,results,settings,imports,exports,paper,guide}[S.page]||ownTask)(S);
}""")
s=s.replace("heading('Configuración del operativo','La preparación técnica, el inicio de operación y la difusión son decisiones distintas.')","heading('Jornada','Fecha, recepción y conservación de datos.')").replace("${(S.boot.actor.is_super_admin?button('Estado técnico','preflight'):'')}",'')
s=s.replace('<section class="card"><h2>Acceso directo</h2><p>La empresa utiliza sus funciones después de ingresar. La recepción y la difusión se administran por separado.</p></section>','')
s=s.replace('<section class="card"><h2>3. Ubicación puntual (opcional)</h2>','<details class="card capture-geo"><summary>Ubicación del encuestador (opcional)</summary>').replace("${button('Sin GPS','clear-gps')}</div></section><div class=\"capture-actions", "${button('Sin GPS','clear-gps')}</div></details><div class=\"capture-actions")
s=s.replace("heading(S.page==='review'?'Revisión independiente':'Mis registros','Datos del servidor, paginados. No es una copia de seguridad.')", "heading(S.page==='review'?'Revisión de registros':'Mis registros',S.page==='review'?'Página del servidor. Solo se ofrecen para revisión los registros pendientes.':'Datos personales del servidor, por páginas.')")
s=s.replace("${S.page==='review'?button('Revisar','review-decision',r.id,'small'):r.disposition!=='excluded'?button('Anular error propio','void',r.id,'small danger'):''}","${S.page==='review'?(r.disposition==='pending_review'?button('Revisar','review-decision',r.id,'small'):''):r.disposition!=='excluded'?button('Anular error propio','void',r.id,'small danger'):''}")
s=s.replace('<small>${E(r.id)} · ${E(r.reason_code)}</small>','<details><summary>Detalle</summary><small>${E(r.id)} · ${E(r.reason_code)}</small></details>').replace('Auditoría (últimos 10.000 eventos)','Auditoría completa (máximo 100.000 eventos)');p.write_text(s)
p=R/'v3/web/modules/company.mjs';s=p.read_text().replace("a?.is_super_admin===true?'Super Admin · propietario':ROLES[a?.role]||'Sin rol'","ROLES[a?.role]||'Sin rol'")
s=re.sub(r"const warning=\(\)=>.*?;\n","const warning=()=>'<section class=\"card callout warn\"><h2>Actualización pendiente</h2><p>La gestión de cuentas no está disponible. Contacte al soporte de la plataforma.</p></section>';\n",s,count=1)
s=s.replace('Crear coordinadores y viewers. El Super Admin también crea administradores.','Crear accesos individuales con los permisos correspondientes.').replace('<h1>Empresa e inicio</h1>','<h1>Empresa</h1>').replace('${E(roleLabel(b.actor))}. Prepare datos por etapas; no hace falta reunir a las 60 personas.','Datos de contacto y preparación del operativo.')
s=s.replace('<p class="inline-note">Prepare los datos al ingresar. Abra la recepción y autorice la difusión solamente cuando corresponda; no hay un paso de activación de versión.</p>','').replace('<a class="button" href="manual-es-zh.html" target="_blank" rel="noopener">Manual español / 繁體中文</a>','')
s=s.replace("'Un acceso por persona. El Super Admin gestiona administradores; la empresa gestiona su equipo.'","'Cuentas individuales y permisos de trabajo.'").replace("b.actors.filter(a=>a.role!=='interviewer')","b.actors.filter(a=>a.role!=='interviewer'&&!a.is_super_admin)").replace("${a.is_super_admin?'<span class=\"badge\">Cuenta protegida</span>':''}",'').replace('export function companyPage(S){return companyPageBase(S)+readinessCard(S);}','export function companyPage(S){return companyPageBase(S);}')
p.write_text(s)
(R/'v3/web/modules/company-readiness.mjs').write_text("/** Technical state is intentionally not displayed in the work interface. */\nexport const isCompanyAdmin=b=>b?.actor?.role==='admin'&&b.actor.is_super_admin===false;\nexport function readinessCard(){return '';}\n")
p=R/'v3/web/index.html';p.write_text(p.read_text().replace('</head>','<link rel="stylesheet" href="workspace.css">\n</head>'))
p=R/'v3/web/app.mjs';s="import * as W from './modules/workspace.mjs';\n"+p.read_text();s=s.replace('records:[],moreRecords:false','records:[],moreRecords:false,ui:W.freshUI(),registry:null,aliases:{},refreshError:false')
s=s.replace('async function enter(session){','async function enter(session){S.ui=W.freshUI();S.registry=null;S.aliases={};')
s=s.replace("const b=await api.rpc('v3_bootstrap',{p_client:C.CLIENT});S.boot=b;S.offline=false;S.lastSync=new Date().toISOString();","const b=await api.rpc('v3_bootstrap',{p_client:C.CLIENT});S.boot=b;S.ui=W.normalizeFilters(b,S.ui);S.offline=false;S.refreshError=false;if(!S.ui.paused)S.lastSync=new Date().toISOString();")
s=s.replace("if(['admin','coordinator'].includes(b.actor.role)||b.actor.role==='viewer'&&b.operation.viewer_enabled)S.dashboard=await api.rpc('v3_dashboard');else S.dashboard=null;","if(['admin','coordinator'].includes(b.actor.role)||b.actor.role==='viewer'&&b.operation.viewer_enabled){if(!S.ui.paused||force){S.dashboard=await api.rpc('v3_dashboard');S.lastSync=S.dashboard?.server_time||S.lastSync;}}else S.dashboard=null;")
s=s.replace("if(S.page==='company'&&force)await loadReadiness();",'').replace("if(force||!S.modal&&!document.querySelector('form:not(#login-form)')&&!['capture','imports'].includes(S.page))render();","if(force||!S.modal&&!document.querySelector('form:not(#login-form)')&&!document.activeElement?.matches('input,textarea,select')&&!['capture','imports'].includes(S.page)&&!(S.page==='overview'&&S.ui.paused))render();")
s=s.replace('S.pack=null;S.boot=null;S.queue=[];S.unlock=false;close();error(e);','S.pack=null;S.boot=null;S.queue=[];S.registry=null;S.aliases={};S.unlock=false;close();error(e);').replace('else{S.offline=!navigator.onLine;if(force)error(e);}','else{S.offline=!navigator.onLine;S.refreshError=true;if(force)error(e);}')
s=s.replace('Solo el Super Admin revisa la instalación; la empresa puede preparar datos y usuarios.','Contacte al soporte; puede preparar datos y usuarios.').replace("if(page==='company')await loadReadiness();","if(page==='registry')await loadRegistry();")
s=s.replace('S.readiness=null;S.readinessError=null;S.boot=null;S.session=null;','S.readiness=null;S.readinessError=null;S.registry=null;S.aliases={};S.ui=W.freshUI();S.boot=null;S.session=null;')
s=s.replace('async function click(action,id,el){',"""async function loadRegistry(){
 if(S.boot?.actor.role!=='admin')throw new Error('V3_SCOPE_DENIED');
 const snap=await W.readSnapshot(api,C.uuid());const aliases={};
 for(const qid of [...new Set(snap.data.filter(r=>r.candidate_id).map(r=>r.questionnaire_id))]){
  try{const a=await api.rpc('v3_report_config',{p_questionnaire:qid});if(a.confirmed)aliases[qid]=a;}catch(e){if(/SESSION|ACCOUNT_DISABLED/.test(e.message))throw e;}
 }
 S.registry=snap;S.aliases=aliases;S.ui.recordPage=0;
}
async function changeFilter(key,value){S.ui={...S.ui,[key]:value,recordPage:0};if(key==='city')Object.assign(S.ui,{station:'',point:'',person:''});if(key==='station')Object.assign(S.ui,{point:'',person:''});if(key==='point')S.ui.person='';S.ui=W.normalizeFilters(S.boot,S.ui);render();}
async function click(action,id,el){""")
s=s.replace("case 'logout':await logout();", """case 'filter-city':await changeFilter('city',id);break;
 case 'filter-reset':S.ui=W.freshUI();render();break;
 case 'search-apply':await changeFilter('search',document.getElementById('workspace-search')?.value||'');break;
 case 'board-pause':S.ui.paused=!S.ui.paused;if(!S.ui.paused)await refresh(true);else render();break;
 case 'city-points':await changeFilter('city',id);await navigate('points');break;
 case 'focus-point':{const p=currentPoint(id),st=S.boot.stations.find(s=>s.id===p?.station_id);if(!st)throw new Error('V3_NOT_FOUND');Object.assign(S.ui,{city:st.district_id,station:st.id,point:id,person:'',recordPage:0});await navigate('points');break;}
 case 'point-records':{const p=currentPoint(id),st=S.boot.stations.find(s=>s.id===p?.station_id);if(!st)throw new Error('V3_NOT_FOUND');Object.assign(S.ui,{city:st.district_id,station:st.id,point:id,person:'',recordPage:0});close();await navigate('registry');break;}
 case 'point-assign':{const p=currentPoint(id);if(!p||!['approved','paused','open'].includes(p.state))throw new Error('V3_POINT_OR_VERSION_CLOSED');form('Asignar persona','assignment-form',V.select('Persona','person_id',S.boot.people.map(p=>({id:p.id,name:p.code+' · '+p.display_name})))+V.select('Punto aprobado','point_id',S.boot.points.filter(p=>['approved','paused','open'].includes(p.state)).map(p=>({id:p.id,name:V.namePoint(S.boot,p.id)})),id)+reason());break;}
 case 'person-detail':modal('Ficha de la persona',W.personDetail(S,id,V));break;
 case 'person-records':Object.assign(S.ui,W.freshUI(),{person:id});close();await navigate('registry');break;
 case 'person-filter-clear':S.ui.person='';render();break;
 case 'registry-refresh':await loadRegistry();render();break;
 case 'registry-export':if(S.boot.actor.role!=='admin'||!S.registry)throw new Error('V3_SCOPE_DENIED');C.download(W.registryCSV(S),'Pulso_INTERNO_filtrado.csv','text/csv;charset=utf-8');break;
 case 'record-page':S.ui.recordPage=Math.max(0,Number(id)||0);render();break;
 case 'record-detail':{const r=W.recordRows(S).find(r=>r.id===id);if(!r)throw new Error('V3_NOT_FOUND');modal('Detalle del registro',`<p>${E(r.candidate_name)} · ${E(r.candidate_list)}</p><p>Encuesta: ${C.time(r.captured_at)}<br>Recepción: ${C.time(r.received_at)}</p><p>${E(r.station_name)} · ${E(r.point_label)}</p><p>Versión ${E(r.questionnaire_version)} · ${E(C.STATE[r.disposition])}</p><details><summary>Identificadores de auditoría</summary><pre>${E(JSON.stringify(r,null,2))}</pre></details>`);break;}
 case 'logout':await logout();""")
s=s.replace('S.queue=await vault.entries();if(S.pack)await',"S.queue=await vault.entries();if(S.page==='capture'){const node=document.querySelector('.capture-activity');if(node)node.outerHTML=W.captureActivity(S);}if(S.pack)await")
s=s.replace("document.addEventListener('change',e=>{", """document.addEventListener('change',e=>{
 const map={'workspace-station':'station','workspace-point':'point','workspace-search':'search','record-status':'recordStatus','record-from':'from','record-to':'to'};
 if(map[e.target.id]){if(S.busy)return;changeFilter(map[e.target.id],e.target.value).catch(error);return;}
""")
s=s.replace("window.addEventListener('online',()=>{refresh(true).then(()=>sync()).catch(error);});","window.addEventListener('online',()=>{refresh().then(()=>sync()).catch(error);});").replace(" case 'activate-form':throw new Error('V3_USE_COMPANY_CONFIRMATIONS');\n",'')
p.write_text(s)
p=R/'v3/scripts/build.mjs';s=p.read_text().replace("'index.html','styles.css','manifest.webmanifest'","'index.html','styles.css','workspace.css','manifest.webmanifest'").replace("'3.1.2'","'3.1.3'").replace("['templates','manual-es.html','manual-es-zh.html']","['templates','manual-es.html']");p.write_text(s)
p=R/'v3/tests/company-ui.test.mjs';p.write_text(p.read_text().replace('assert.match(roleLabel(root),/Super Admin/)',"assert.equal(roleLabel(root),'Administrador')"))
p=R/'v3/tests/company-handoff-ui.test.mjs';s=p.read_text().replace("assert(h.includes('Acceso directo V3.1'))","assert.equal(h,'')").replace("assert(h.includes('sin verificar'));assert(h.includes('Super Admin'));assert(!h.includes('instalado ·'))","assert.equal(h,'');assert(!h.includes('Super Admin'))").replace("assert(h.includes('Módulo 013: instalado'));assert(h.includes('Acceso directo: instalado'))","assert.equal(h,'')").replace("assert(h.includes('&lt;script&gt;'));","assert.equal(h,'');");p.write_text(s)
nav='''def nav(page,name):
 page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
 groups={'tasks':'people','access':'people','catalog':'company','imports':'company','exports':'company','settings':'company','review':'registry','paper':'registry','task':'capture'}
 target=page.locator('[data-action=nav][data-id="'+name+'"]:visible')
 if not target.count():
  page.locator('[data-action=nav][data-id="'+groups.get(name,name)+'"]:visible').first.click()
  page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
 page.locator('[data-action=nav][data-id="'+name+'"]:visible').first.click()
 page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
'''
for file in ['v3/tests/company-browser.py','v3/tests/company-native-browser.py']:
 p=R/file;s=p.read_text();s,n=re.subn(r'(?m)^def nav\([^\n]+\):\n(?:[ \t]+[^\n]*\n)+',nav,s,count=1);assert n==1
 s=s.replace("name='Centro de operación'","name='Resultados'").replace("check('Super label displayed from server bootstrap',page.get_by_text('Super Admin · propietario',exact=False).count()>0)","check('Privilege label is not displayed',page.get_by_text('Super Admin · propietario',exact=False).count()==0)")
 s=s.replace("nav(page,'people');action(page,'person-rename');","nav(page,'people');action(page,'person-detail');action(page,'person-rename');").replace("page.locator('#mobile-nav option[value=company],#mobile-nav option[value=access]').count()==0","page.locator('[data-action=nav][data-id=company],[data-action=nav][data-id=access]').count()==0")
 p.write_text(s)
p=R/'v3/tests/live-native-browser.py';s=p.read_text().replace("w.locator('#mobile-nav').select_option('queue')","w.locator('[data-action=nav][data-id=queue]:visible').first.click()").replace("w.locator('#mobile-nav').select_option('task')","w.locator('[data-action=nav][data-id=capture]:visible').first.click();field_done(w);w.locator('[data-action=nav][data-id=task]:visible').first.click()");p.write_text(s)
p=R/'v3/direct/browser.py';s=p.read_text().replace("page.locator('[data-company-readiness]').wait_for(timeout=20000)\n page.get_by_text('Acceso directo V3.1',exact=True).wait_for(timeout=20000)\n check(engine+' authenticated page shows direct V3.1 use',True)","page.locator('#company-form').wait_for(timeout=20000)\n check(engine+' authenticated company form is immediately available',True)");p.write_text(s)
(R/'v3/web/manual-es-zh.html').unlink(missing_ok=True)
print('Workspace integrated. SQL, Auth, permissions, local vault and capture validation are not rewritten.')
