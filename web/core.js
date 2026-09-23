/* Pulso v2.0.0 — pure calculations, anonymous demo data and durable outbox. */
(function(root){
  'use strict';
  const DISTRICTS=[
    {id:'cde',code:'CDE',name:'Ciudad del Este',target_agents:15},
    {id:'minga',code:'MGA',name:'Minga Guazú',target_agents:15},
    {id:'hernandarias',code:'HER',name:'Hernandarias',target_agents:15},
    {id:'franco',code:'PFR',name:'Presidente Franco',target_agents:15}
  ];
  const OUTCOMES={candidate:'Candidatura',blank:'Voto en blanco',invalid:'Voto nulo',undisclosed:'No revela su voto',refused:'Rechaza la encuesta'};
  const PALETTE=['#087e7b','#8271cc','#537fbc','#ba8454','#598755','#be6691','#776c59','#6879a8','#72864c','#ac739f','#508f9a','#967647'];
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const fmt=n=>new Intl.NumberFormat('es-PY').format(Number(n)||0);
  const pct=(n,d)=>d>0?Number(n)/Number(d)*100:0;
  const percent=n=>new Intl.NumberFormat('es-PY',{maximumFractionDigits:1,minimumFractionDigits:1}).format(Number(n)||0)+' %';
  function uuid(){if(root.crypto?.randomUUID)return root.crypto.randomUUID();const b=new Uint8Array(16);root.crypto.getRandomValues(b);b[6]=b[6]&15|64;b[8]=b[8]&63|128;return [...b].map((x,i)=>([4,6,8,10].includes(i)?'-':'')+x.toString(16).padStart(2,'0')).join('');}
  function csvCell(v){let s=String(v??'');if(/^[\s]*[=+\-@\t\r]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"';}
  function csv(rows){return '\ufeff'+rows.map(r=>r.map(csvCell).join(';')).join('\r\n');}
  function time(v,seconds=false){if(!v)return 'Sin señal';const d=new Date(v);if(Number.isNaN(d.getTime()))return '—';return new Intl.DateTimeFormat('es-PY',{timeZone:'America/Asuncion',hour:'2-digit',minute:'2-digit',...(seconds?{second:'2-digit'}:{}),hour12:false}).format(d);}
  function localDate(v=new Date()){return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Asuncion',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(v));}
  // User-provided catalogue, 22 September 2026. Not certified by the TSJE.
  const CATALOG={
    cde:[['Rigo Chamorro','Lista 1'],['Dani Mujica','Lista 123']],
    hernandarias:[['Oscar “Melli” González','Lista 1'],['José Castillo','Lista 2026']],
    minga:[['César Paredes','Lista 1'],['Mónica Ramírez','Lista 123'],['Roberto Almiron','Lista 6'],['Tania Mabel Meza','Lista 44']],
    franco:[['Arnold Ramírez','Lista 1'],['Roya Torres','Lista 2'],['Henry González','Lista 3'],['Mabel Otazú','Lista 123']]
  };
  function makeDemo(now=Date.now()){
    const profiles=[],candidates=[],stations=[],records=[];
    DISTRICTS.forEach(d=>{
      for(let j=1;j<=3;j++)stations.push({id:`${d.id}-p${j}`,district_id:d.id,code:`${d.code}-L${String(j).padStart(2,'0')}`,name:`Local de práctica ${j} · NO OFICIAL`,address:'Dirección real pendiente de configurar',point_label:'Punto de encuesta por definir',latitude:null,longitude:null,active:true,is_template:true});
      CATALOG[d.id].forEach(([name,list_label],i)=>candidates.push({id:`${d.id}-c${i+1}`,district_id:d.id,name,list_label,sort_order:i,active:true,is_template:false}));
      for(let i=1;i<=15;i++)profiles.push({id:`demo-${d.code}-${i}`,code:`${d.code}-${String(i).padStart(2,'0')}`,display_name:'',role:'interviewer',district_id:d.id,station_id:`${d.id}-p${1+(i-1)%3}`,slot:i,active:true,last_seen:null});
    });
    // Deliberately zero observations. Never seed invented vote shares with real candidate names.
    return {settings:{id:1,title:'Municipales 2026 · Alto Paraná',contest:'Intendencia municipal',fieldwork_date:'2026-10-04',state:'open',sample_interval:5,goal_per_district:1000,methodology:'Protocolo pendiente de aprobación: definir locales, turnos e intervalo de selección antes del operativo real.',catalog_confirmed:false,viewer_enabled:true,opened_at:new Date(now).toISOString(),closed_at:null},profiles,candidates,stations,records,created_at:new Date(now).toISOString()};
  }
  function summarize(meta,records,now=Date.now(),filters={}){
    const usable=records.filter(r=>!r.voided_at&&(!filters.station_id||r.station_id===filters.station_id)&&(!filters.from||r.captured_at>=filters.from)&&(!filters.to||r.captured_at<=filters.to));
    const districts=DISTRICTS.filter(d=>!filters.station_id||meta.stations.some(st=>st.id===filters.station_id&&st.district_id===d.id)).map(d=>{
      const rr=usable.filter(r=>r.district_id===d.id);
      const count=o=>rr.reduce((n,r)=>n+(r.outcome===o?1:0),0);
      const candidates=meta.candidates.filter(c=>c.district_id===d.id&&c.active).map(c=>({...c,count:rr.filter(r=>r.outcome==='candidate'&&r.candidate_id===c.id).length})).sort((a,b)=>a.sort_order-b.sort_order);
      const valid=count('candidate'),refused=count('refused');
      const agents=meta.profiles.filter(p=>p.district_id===d.id&&p.role==='interviewer'&&(!filters.station_id||p.station_id===filters.station_id)).map(p=>{const own=rr.filter(r=>r.agent_id===p.id);return {...p,count:own.length,last_captured:own.reduce((t,r)=>r.captured_at>t?r.captured_at:t,'')||null,last_received:own.reduce((t,r)=>r.received_at>t?r.received_at:t,'' )||null};});
      const st=meta.stations.filter(s=>s.district_id===d.id&&s.active&&(!filters.station_id||s.id===filters.station_id)).map(s=>{const sr=rr.filter(r=>r.station_id===s.id);return {...s,count:sr.length,answered:sr.filter(r=>r.outcome!=='refused').length,valid:sr.filter(r=>r.outcome==='candidate').length,candidates:candidates.map(c=>({...c,count:sr.filter(r=>r.candidate_id===c.id).length})),agents:agents.filter(p=>p.station_id===s.id).map(p=>({...p,count:sr.filter(r=>r.agent_id===p.id).length})),last_received:sr.reduce((v,r)=>r.received_at>v?r.received_at:v,'')||null};});
      const hours={};rr.forEach(r=>{const ms=Math.floor(new Date(r.received_at).getTime()/3600000)*3600000;hours[ms]=(hours[ms]||0)+1;});const captureHours={};rr.forEach(r=>{const ms=Math.floor(new Date(r.captured_at).getTime()/3600000)*3600000;captureHours[ms]=(captureHours[ms]||0)+1;});
      return {...d,total:rr.length,answered:rr.length-refused,valid,refused,blank:count('blank'),invalid:count('invalid'),undisclosed:count('undisclosed'),candidates,agents,stations:st,capture_hours:Object.entries(captureHours).map(([ts,count])=>({hour:new Date(Number(ts)).toISOString(),count})).sort((a,b)=>a.hour.localeCompare(b.hour)),hours:Object.entries(hours).map(([ts,count])=>({hour:new Date(Number(ts)).toISOString(),count})).sort((a,b)=>a.hour.localeCompare(b.hour))};
    });
    return {settings:meta.settings,districts,generated_at:new Date(now).toISOString()};
  }
  function aggregateCsv(snapshot,mode){
    const rows=[['MODO','GENERADO_UTC','TIPO','DISTRITO','CATEGORIA','CONTACTOS_O_RESPUESTAS','BASE_CANDIDATURAS','PORCENTAJE_BASE_CANDIDATURAS','ADVERTENCIA']];
    for(const d of snapshot.districts){
      for(const c of d.candidates)rows.push([mode,snapshot.generated_at,'candidatura',d.name,c.name,c.count,d.valid,d.valid?(c.count/d.valid*100).toFixed(2):'','Muestra no ponderada. No es resultado oficial. Difusión restringida.']);
      for(const o of ['blank','invalid','undisclosed','refused'])rows.push([mode,snapshot.generated_at,'otra_categoria',d.name,OUTCOMES[o],d[o],'','','No forma parte de la base de candidaturas.']);
      rows.push([mode,snapshot.generated_at,'total',d.name,'Contactos',d.total,'','','Incluye rechazos; no representa al padrón.']);
    }
    return csv(rows);
  }
  function validateCapture(event,profile,candidates){
    if(!profile||profile.role!=='interviewer'||!profile.active)throw new Error('Se requiere un encuestador activo.');
    if(!profile.station_id)throw new Error('Falta asignar el local de encuesta.');
    if(event.station_id!==profile.station_id)throw new Error('El local no coincide con su asignación.');
    if(!event.already_voted)throw new Error('Confirme que la persona ya emitió su voto.');
    if(!Object.hasOwn(OUTCOMES,event.outcome))throw new Error('Seleccione una respuesta válida.');
    if(event.outcome!=='refused'&&!event.consent)throw new Error('Se necesita participación voluntaria.');
    if(event.outcome==='refused'&&(event.consent||event.candidate_id))throw new Error('Un rechazo no puede incluir una preferencia.');
    if(event.outcome==='candidate'&&!candidates.some(c=>c.id===event.candidate_id&&c.district_id===profile.district_id&&c.active))throw new Error('La candidatura no pertenece a su distrito.');
    if(event.outcome!=='candidate'&&event.candidate_id)throw new Error('La categoría no admite una candidatura.');
    if(!event.id||!event.captured_at||Number.isNaN(new Date(event.captured_at).getTime()))throw new Error('Registro inválido.');
    const captured=new Date(event.captured_at).getTime(),started=new Date(event.started_at).getTime();
    if(!event.started_at||!Number.isFinite(started)||started>captured||captured-started>7200000)throw new Error('Revise la hora de inicio de la encuesta.');
    const status=event.geo_status||'not_requested';
    if(!['not_requested','granted','denied','unavailable','stale'].includes(status))throw new Error('Estado de ubicación inválido.');
    if(status==='granted'){
      const gt=new Date(event.geo_captured_at).getTime();
      if(!Number.isFinite(event.latitude)||!Number.isFinite(event.longitude)||Math.abs(event.latitude)>90||Math.abs(event.longitude)>180||!Number.isFinite(event.accuracy_m)||event.accuracy_m<0||event.accuracy_m>100000||!event.geo_captured_at||!Number.isFinite(gt)||gt>captured+30000||gt<captured-900000)throw new Error('Ubicación operativa inválida o antigua.');
    }else if([event.latitude,event.longitude,event.accuracy_m,event.geo_captured_at].some(v=>v!=null))throw new Error('No envíe coordenadas sin autorización.');
    return true;
  }
  class Store{
    constructor(){this.db=null;}
    async open(){if(this.db)return this;this.db=await new Promise((resolve,reject)=>{const r=indexedDB.open('pulso-anonymous-v2',1);r.onupgradeneeded=()=>{const d=r.result;for(const n of ['meta','outbox','demo_events'])if(!d.objectStoreNames.contains(n))d.createObjectStore(n,{keyPath:'id'});};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(new Error('No se puede abrir el almacenamiento local. No se guardó ningún registro.'));r.onblocked=()=>reject(new Error('Cierre otras versiones de Pulso y vuelva a abrir.'));});return this;}
    async request(store,method,arg){await this.open();return new Promise((resolve,reject)=>{const tx=this.db.transaction(store,method==='get'||method==='getAll'?'readonly':'readwrite'),s=tx.objectStore(store);const r=arg===undefined?s[method]():s[method](arg);let result;r.onsuccess=()=>{result=r.result;};tx.oncomplete=()=>resolve(result);tx.onabort=tx.onerror=()=>reject(tx.error||new Error('No fue posible guardar en este dispositivo.'));});}
    get(store,id){return this.request(store,'get',id);}all(store){return this.request(store,'getAll');}put(store,obj){return this.request(store,'put',obj);}delete(store,id){return this.request(store,'delete',id);}clear(store){return this.request(store,'clear');}
    async seedDemo(force=false){let found=await this.get('meta','demo');if(found&&!force)return found.value;const demo=makeDemo();await this.open();return new Promise((resolve,reject)=>{const tx=this.db.transaction(['meta','demo_events'],'readwrite');tx.objectStore('demo_events').clear();for(const r of demo.records)tx.objectStore('demo_events').put(r);const {records,...meta}=demo;tx.objectStore('meta').put({id:'demo',value:meta});tx.oncomplete=()=>resolve(meta);tx.onerror=()=>reject(tx.error);});}
    async queue(environment,owner){return (await this.all('outbox')).filter(q=>q.environment===environment&&q.owner===owner).sort((a,b)=>a.event.captured_at.localeCompare(b.event.captured_at));}
  }
  // DEMO ONLY fallback for HTML previewers / storage-restricted browsers.
  // Never use this store for real survey capture. app.js blocks cloud mode.
  class VolatileDemoStore {
    constructor(){this.data={meta:new Map(),outbox:new Map(),demo_events:new Map()};this.volatile=true;}
    async open(){return this;}
    async get(s,id){return structuredClone(this.data[s].get(id));}
    async all(s){return [...this.data[s].values()].map(v=>structuredClone(v));}
    async put(s,v){this.data[s].set(v.id,structuredClone(v));}
    async delete(s,id){this.data[s].delete(id);}
    async clear(s){this.data[s].clear();}
    async seedDemo(force=false){const found=await this.get('meta','demo');if(found&&!force)return found.value;const demo=makeDemo();const {records,...meta}=demo;await this.clear('demo_events');for(const r of records)await this.put('demo_events',r);await this.put('meta',{id:'demo',value:meta});return meta;}
    async queue(environment,owner){return(await this.all('outbox')).filter(q=>q.environment===environment&&q.owner===owner).sort((a,b)=>a.event.captured_at.localeCompare(b.event.captured_at));}
  }
  const api={CATALOG,DISTRICTS,OUTCOMES,PALETTE,esc,fmt,pct,percent,uuid,csv,csvCell,time,localDate,makeDemo,summarize,aggregateCsv,validateCapture,Store,VolatileDemoStore};
  root.PulsoCore=api;if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window!=='undefined'?window:globalThis);
