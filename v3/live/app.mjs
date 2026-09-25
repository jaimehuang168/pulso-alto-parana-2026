import {LiveReader} from './reader.mjs';
import {CITIES,validate,card,selected,number,clock,exportCSV,exportSVG,escape} from './core.mjs';
import {demoSource} from './demo.mjs';
const DEMO=__LIVE_DEMO__;
if(innerWidth>=1100)document.body.classList.add('tv');
const $=id=>document.getElementById(id),query=new URLSearchParams(location.search);
let display=null,city=CITIES.some(c=>c.id===query.get('city'))?query.get('city'):'all',rotating=false,rotationTimer,reader,sb,channel,heartbeat,toastTimer,state='loading',offlineDemo=false,lastSignal=0;
const requested=['internal','codes','released'].includes(query.get('view'))?query.get('view'):'auto';
const demo=DEMO?demoSource():null;
function toast(text){clearTimeout(toastTimer);$('toast').textContent=text;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,6000);}
function explain(e){const s=String(e?.message||e||'')+String(e?.code||'');
 if(/PGRST202|MIGRATION_REQUIRED|CONNECTION_NOT_CONFIGURED|SDK_NOT_LOADED/.test(s))return 'Actualización del backend pendiente. Instale V3 y los complementos 009 + 010 en el proyecto correcto. Esta pantalla no cambia la base de datos ni usa datos de demostración como sustituto.';
 if(/VIEWER_RESULTS_PENDING/.test(s))return 'Acceso de Viewer pendiente. Administración debe autorizar el canal en vivo; no basta con publicar un informe estático.';
 if(/SCOPE_DENIED|ADMIN_ONLY/.test(s))return 'Su cuenta no tiene permiso para esta vista. El monitor no muestra datos fuera de su alcance.';
 if(/ACCOUNT_DISABLED|SESSION_REQUIRED|42501/.test(s)||e?.status===401)return 'La cuenta no está habilitada o la sesión terminó. Vuelva a ingresar; no se muestran resultados anteriores.';
 if(/LIVE_UNSAFE_DATA/.test(s))return 'Respuesta incompatible o campos no permitidos. Se ocultaron los resultados para evitar una salida incorrecta.';
 if(/invalid.*credentials/i.test(s))return 'El código o correo y la contraseña no coinciden.';
 return 'No se pudo confirmar una actualización. La última recepción no se convierte en cero. Revise la conexión y pulse Actualizar.';
}
function notice(text){$('notice').textContent=text;$('notice').hidden=!text;}
function setState(s,e){if(display&&reader?.age()>=15&&['loading','offline'].includes(s))s='stale';state=s;const labels={loading:'ACTUALIZANDO',live:DEMO?'DEMO EN MOVIMIENTO':'ACTUALIZACIÓN ACTIVA',paused:'PANTALLA EN PAUSA',offline:'SIN CONEXIÓN',denied:'ACCESO BLOQUEADO',stale:'DATOS NO ACTUALES'};
 $('connection').className='connection '+s;$('connection').textContent=labels[s]||s;
 if(e){if(/LIVE_UNSAFE_DATA/.test(String(e.message))){display=null;render();}notice(explain(e));}else if(s==='live'||s==='loading')notice('');
 if(s==='stale'&&display)notice('DATOS SIN ACTUALIZAR. Última consulta confirmada a las '+clock(display.server_time)+'. No interprete esta pantalla como datos actuales.');
 if(s==='denied'&&e&&!DEMO&&/SESSION_REQUIRED|ACCOUNT_DISABLED|Invalid JWT|42501/.test(String(e?.message||'')+String(e?.code||'')))$('access').hidden=false;
 if(s==='paused')notice('Pantalla en pausa. La encuesta y la recepción del servidor continúan. Reanude para ver los nuevos datos.');
 $('pause').textContent=reader?.paused?'▶ Reanudar':'Ⅱ Pausar';
}
function accept(value){display=value;if(value){$('access').hidden=true;$('monitor').hidden=false;$('server-clock').textContent=clock(value.server_time);$('freshness').textContent='Consulta confirmada ahora · nueva consulta cada 5 s';
 $('audience').value=value.audience;
 for(const o of $('audience').options)o.disabled=!value.can_internal&&o.value!=='released';
 if(!value.can_internal&&city!=='all'&&!value.cities.some(c=>c.id===city))city='all';
 }render();}
function render(){
 $('monitor').hidden=false;
 if(!display){$('png').disabled=true;$('csv').disabled=true;$('board').innerHTML='<div class="loading-screen">Esperando una respuesta autorizada del servidor. No se muestran cifras sin confirmar.</div>';return;}
 const text=DEMO?'DEMOSTRACIÓN · DATOS FICTICIOS · NO ES UNA MEDICIÓN REAL':display.audience==='internal'?'ADMINISTRACIÓN · NOMBRES REALES · USO INTERNO / NO DIFUNDIR':display.private?'PREVISUALIZACIÓN PRIVADA · SOLO CÓDIGOS · NO DIFUNDIR':'CANAL AUTORIZADO · SOLO CÓDIGOS · DENTRO DE SU ALCANCE';
 $('audience-banner').textContent=text;$('audience-banner').className='audience-banner '+(DEMO?'demo':display.audience==='internal'?'internal':'');
 $('board').className='board '+(city==='all'?'four':'single');const rows=selected(display,city);
 $('board').innerHTML=rows.map(c=>card(c,display.audience)).join('')||'<div class="loading-screen">No hay ciudades autorizadas en esta cuenta.</div>';
 for(const b of $('city-tabs').querySelectorAll('button')){b.classList.toggle('selected',b.dataset.city===city);b.setAttribute('aria-pressed',String(b.dataset.city===city));b.disabled=b.dataset.city!=='all'&&!display.cities.some(c=>c.id===b.dataset.city);}
 $('scope-name').textContent=city==='all'?(rows.length===4?'Cuatro ciudades · actualización continua':rows.length+' ciudad(es) dentro de su alcance'):(CITIES.find(c=>c.id===city)?.name||'')+' · vista ampliada';
 $('png').disabled=!rows.length;$('csv').disabled=!rows.length;
 if(DEMO)$('mode-detail').textContent='DEMO: nuevas respuestas ficticias cada 5 segundos. No conectado a Supabase. Puede simular una desconexión.';
}
function pick(value,manual=true){city=value;if(manual&&rotating)rotate(false);render();try{const u=new URL(location.href);u.searchParams.set('city',value);history.replaceState(null,'',u);}catch{}}
function rotate(value){rotating=value;clearInterval(rotationTimer);$('rotate').textContent=value?'■ Detener rotación':'↔ Rotación';$('rotate').classList.toggle('selected',value);if(value){const ids=display?.cities.map(c=>c.id)||[];if(!ids.length)return;if(city==='all')pick(ids[0],false);rotationTimer=setInterval(()=>{const current=display?.cities.map(c=>c.id)||[];if(current.length)pick(current[(current.indexOf(city)+1)%current.length],false);},15000);}}
function download(text,name,type){const blob=text instanceof Blob?text:new Blob([text],{type}),u=URL.createObjectURL(blob),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),30000);}
function filename(ext){return 'Pulso_'+(DEMO?'DEMO_':display.private?'PRIVADO_NO_DIFUNDIR_':'CODIGOS_AUTORIZADO_')+(city==='all'?'4_CIUDADES':CITIES.find(c=>c.id===city).code)+'_'+display.server_time.replace(/[^0-9]/g,'').slice(0,14)+'.'+ext;}
async function png(){if(!display)return;try{const data=validate(display),svg=exportSVG(data,city,DEMO,!reader.paused&&reader.age()<15),url=URL.createObjectURL(new Blob([svg],{type:'image/svg+xml;charset=utf-8'}));
 try{const img=new Image();await new Promise((resolve,reject)=>{img.onload=resolve;img.onerror=()=>reject(new Error('PNG_RENDER_FAILED'));img.src=url;});const canvas=document.createElement('canvas');canvas.width=img.width;canvas.height=img.height;canvas.getContext('2d').drawImage(img,0,0);const b=await new Promise(r=>canvas.toBlob(r,'image/png'));if(!b)throw new Error('PNG_RENDER_FAILED');download(b,filename('png'),'image/png');toast('PNG guardado como captura con hora. La pantalla continúa actualizándose.');}finally{URL.revokeObjectURL(url);}}
 catch(e){toast('No se pudo crear el PNG. Use la captura SVG incluida en el paquete o informe a administración.');}}
async function cloud(mode,signal){
 const {data,error}=await sb.rpc('v3_live_board',{p_audience:mode,p_district:null}).abortSignal(signal);
 if(error)throw Object.assign(new Error(error.message),error);return data;
}
async function connectSignal(){
 if(!sb)return;const session=(await sb.auth.getSession()).data.session;if(!session?.access_token)return;
 if(channel)await sb.removeChannel(channel);await sb.realtime.setAuth(session.access_token);
 channel=sb.channel('pulso-live-monitor').on('postgres_changes',{event:'UPDATE',schema:'public',table:'v3_signals'},()=>{
  const now=performance.now();if(reader&&!reader.paused&&now-lastSignal>1000){lastSignal=now;reader.refresh();}
 }).subscribe(status=>{if(status==='SUBSCRIBED'&&reader&&!reader.paused)reader.refresh();});
}
async function start(){
 reader?.stop();reader=new LiveReader(DEMO?demo.load:cloud,accept,setState);$('monitor').hidden=false;$('access').hidden=true;await reader.change(requested);if(!DEMO&&display?.can_internal)connectSignal().catch(()=>{});
}
function tick(){
 if(!reader||!display)return;const age=reader.age(),elapsed=Math.floor(age);
 $('freshness').textContent=(reader.paused?'Pantalla pausada · ':'')+'Consulta confirmada hace '+(Number.isFinite(elapsed)?elapsed:'—')+' s · nueva consulta cada 5 s';
 if(age>=(display.audience==='released'?reader.validFor:15)){
  if(display.audience==='released'){display=null;render();notice('La autorización de esta vista caducó sin una nueva confirmación. Resultados ocultos hasta reconectar.');setState('stale');}
  else if(!reader.paused){setState('stale');notice('DATOS SIN ACTUALIZAR. Última consulta confirmada a las '+clock(display.server_time)+'. No interprete esta pantalla como datos actuales.');}
 }
}
$('leave').hidden=DEMO;$('leave').addEventListener('click',async()=>{reader?.stop();rotate(false);if(channel&&sb)await sb.removeChannel(channel);channel=null;if(sb)await sb.auth.signOut({scope:'local'});display=null;render();$('monitor').hidden=true;$('access').hidden=false;notice('');setState('denied');});
$('city-tabs').addEventListener('click',e=>{const b=e.target.closest('[data-city]');if(b&&!b.disabled)pick(b.dataset.city);});
$('audience').addEventListener('change',()=>{rotate(false);reader.change($('audience').value);});
$('refresh').addEventListener('click',()=>reader?.refresh());$('pause').addEventListener('click',()=>reader?.pause(!reader.paused));$('rotate').addEventListener('click',()=>rotate(!rotating));
$('fullscreen').addEventListener('click',async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else await document.documentElement.requestFullscreen();}catch{document.body.classList.toggle('tv');toast('Modo de presentación activado. La pantalla completa depende del navegador.');}});
addEventListener('resize',()=>{if(!document.fullscreenElement)document.body.classList.toggle('tv',innerWidth>=1100);});
addEventListener('fullscreenchange',()=>document.body.classList.toggle('tv',!!document.fullscreenElement));
$('png').addEventListener('click',png);$('csv').addEventListener('click',()=>{if(display)download(exportCSV(display,city,DEMO),filename('csv'),'text/csv;charset=utf-8');});
$('simulate-offline').hidden=!DEMO;$('simulate-offline').addEventListener('click',()=>{offlineDemo=!offlineDemo;demo.setOffline(offlineDemo);$('simulate-offline').textContent=offlineDemo?'DEMO · restablecer conexión':'DEMO · simular desconexión';reader.refresh();});
$('login-form').addEventListener('submit',async e=>{e.preventDefault();if(!sb)return;const form=e.target,button=form.querySelector('button');button.disabled=true;$('login-error').textContent='';
 try{const code=form.elements.code.value.trim(),password=form.elements.password.value;const {error}=await sb.auth.signInWithPassword({email:code.includes('@')?code:code.toLowerCase()+'@pulso-encuestadores.invalid',password});form.elements.password.value='';if(error)throw error;await start();}catch(e){$('login-error').textContent=explain(e);}finally{button.disabled=false;}});
addEventListener('online',()=>{if(reader&&!reader.paused)reader.refresh();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&reader){tick();if(!reader.paused)reader.refresh();}});
addEventListener('pagehide',()=>{reader?.stop();clearInterval(heartbeat);clearInterval(rotationTimer);if(sb&&channel)sb.removeChannel(channel);});
(async()=>{
 heartbeat=setInterval(tick,1000);
 if(DEMO){await start();return;}
 try{const c=window.PULSO_V3_CONFIG;if(!c?.supabaseUrl||!c.publishableKey||c.simulation)throw new Error('CONNECTION_NOT_CONFIGURED');const u=new URL(c.supabaseUrl);if(u.protocol!=='https:'&&!['127.0.0.1','localhost'].includes(u.hostname))throw new Error('CONNECTION_NOT_CONFIGURED');
  if(c.publishableKey.startsWith('sb_secret_'))throw new Error('CONNECTION_NOT_CONFIGURED');if(c.publishableKey.split('.').length===3){const p=JSON.parse(atob(c.publishableKey.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));if(p.role!=='anon')throw new Error('CONNECTION_NOT_CONFIGURED');}
  if(!window.supabase)throw new Error('SDK_NOT_LOADED');sb=window.supabase.createClient(c.supabaseUrl,c.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false,storageKey:'pulso-v3-auth:'+u.host}});
  const session=(await sb.auth.getSession()).data.session;if(session)await start();else{$('access').hidden=false;$('monitor').hidden=true;setState('denied');}
 }catch(e){$('monitor').hidden=false;accept(null);setState('denied',e);}
})();
