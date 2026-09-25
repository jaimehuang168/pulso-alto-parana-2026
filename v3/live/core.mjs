/** Pure display contract. Codes-only DTOs reject unexpected fields instead of hiding them. */
export const CITIES=[{id:'cde',code:'CDE',name:'Ciudad del Este'},{id:'minga',code:'MGA',name:'Minga Guazú'},{id:'hernandarias',code:'HER',name:'Hernandarias'},{id:'franco',code:'PFR',name:'Presidente Franco'}];
export const COLORS=['#64dbca','#78adff','#f6cd6a','#c6a5ff','#fa9eb2','#9fe3a9','#f0ad78','#acd1dc','#d4b9b3','#8dc8fa','#c6db76','#d1c2f4'];
export const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const number=n=>n==null?'—':new Intl.NumberFormat('es-PY').format(n);
export const percentage=(n,base)=>base>0?new Intl.NumberFormat('es-PY',{minimumFractionDigits:1,maximumFractionDigits:1}).format(n/base*100)+'%':'—';
export const clock=iso=>iso?new Intl.DateTimeFormat('es-PY',{timeZone:'America/Asuncion',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).format(new Date(iso)):'—';
const fail=()=>{throw new Error('LIVE_UNSAFE_DATA');};
const int=n=>Number.isSafeInteger(n)&&n>=0;
function keys(o,allowed){if(!o||Array.isArray(o)||typeof o!=='object'||Object.keys(o).some(k=>!allowed.includes(k)))fail();}
export function validate(raw,requested='auto'){
 keys(raw,['schema','audience','private','can_internal','server_time','valid_until','poll_ms','timezone','election_date','cities','base_definition','limitations']);
 if(raw.schema!=='pulso-live-1'||!['codes','internal','released'].includes(raw.audience)||requested!=='auto'&&requested!==raw.audience)fail();
 if(typeof raw.can_internal!=='boolean'||raw.private!==(raw.audience!=='released')||raw.timezone!=='America/Asuncion'||!Number.isFinite(Date.parse(raw.server_time))||!Number.isFinite(Date.parse(raw.valid_until))||Date.parse(raw.valid_until)<=Date.parse(raw.server_time)||Date.parse(raw.valid_until)-Date.parse(raw.server_time)>15000||raw.poll_ms!==5000||!/^\d{4}-\d{2}-\d{2}$/.test(raw.election_date)||!Array.isArray(raw.cities)||raw.cities.length>4)fail();
 const seen=new Set();for(const c of raw.cities){
  keys(c,['id','city','city_code','state','questionnaire_version','alias_version','counts','candidates','last_received','coverage','other_answers']);
  const city=CITIES.find(x=>x.id===c.id);if(!city||seen.has(c.id)||city.name!==c.city||city.code!==c.city_code||!['catalog_pending','codes_pending','withheld','suppressed','no_data','live'].includes(c.state))fail();seen.add(c.id);
  if(c.questionnaire_version!==null&&(!int(c.questionnaire_version)||c.questionnaire_version<1)||c.alias_version!==null&&(!int(c.alias_version)||c.alias_version<1))fail();
  if(!Array.isArray(c.candidates)||c.candidates.length>12)fail();
  if(['catalog_pending','codes_pending','withheld','suppressed'].includes(c.state)){if(c.counts!==null||c.candidates.length||c.last_received!==null||c.coverage!==null||c.other_answers!==null)fail();continue;}
  keys(c.counts,raw.audience==='released'?['candidate_base']:['candidate_base','received','accepted','pending_review','excluded']);
  if(!int(c.counts.candidate_base))fail();let sum=0;const codes=new Set();
  for(const v of c.candidates){keys(v,raw.audience==='internal'?['code','count','real_name','list']:['code','count']);if(!int(v.count))fail();sum+=v.count;
   if(raw.audience!=='internal'&&(typeof v.code!=='string'||v.code.length<2||v.code.length>40||codes.has(v.code)))fail();codes.add(v.code);
   if(raw.audience==='internal'&&(typeof v.real_name!=='string'||typeof v.list!=='string'))fail();
  }
  if(c.candidates.length<2||sum!==c.counts.candidate_base)fail();
  if(raw.audience!=='released'){
   for(const k of['received','accepted','pending_review','excluded'])if(!int(c.counts[k]))fail();
   keys(c.other_answers,['blank','invalid','undisclosed','refused']);let other=0;for(const k of['blank','invalid','undisclosed','refused']){if(!int(c.other_answers[k]))fail();other+=c.other_answers[k];}
   if(c.counts.candidate_base+other!==c.counts.accepted||c.counts.accepted+c.counts.pending_review+c.counts.excluded!==c.counts.received)fail();
  }else if(c.other_answers!==null)fail();
  if(c.last_received!==null&&(!Number.isFinite(Date.parse(c.last_received))||Date.parse(c.last_received)>Date.parse(raw.server_time)))fail();
  keys(c.coverage,['represented_points','configured_points']);if(!int(c.coverage.represented_points)||!int(c.coverage.configured_points)||c.coverage.represented_points>c.coverage.configured_points)fail();
 }
 return structuredClone(raw);
}
export function donut(c,size=200){
 const base=c.counts?.candidate_base||0;let offset=0;
 const segments=base?c.candidates.map((v,i)=>{const len=v.count/base*100,s=`<circle class="arc" cx="100" cy="100" r="78" pathLength="100" fill="none" stroke="${COLORS[i]}" stroke-width="19" stroke-dasharray="${len} ${100-len}" stroke-dashoffset="${-offset}" transform="rotate(-90 100 100)"/>`;offset+=len;return s;}).join(''):'';
 return `<svg class="donut" width="${size}" height="${size}" viewBox="0 0 200 200" role="img" aria-label="Base de candidaturas: ${number(base)}"><circle cx="100" cy="100" r="78" fill="none" stroke="#243647" stroke-width="19"/>${segments}<text x="100" y="95" text-anchor="middle" fill="#f5f8fc" font-size="32" font-weight="800">${number(base)}</text><text x="100" y="119" text-anchor="middle" fill="#9cb0c4" font-size="11">BASE CANDIDATURAS</text></svg>`;
}
export function card(c,audience){
 const labels={catalog_pending:['Catálogo pendiente','Todavía no hay un formulario publicado.'],codes_pending:['Códigos pendientes','Administración debe confirmar el cruce privado.'],withheld:['Visualización no autorizada','Este canal no ha sido autorizado o su permiso venció.'],suppressed:['Detalle reservado','No se publica el detalle por el umbral de muestra.']};
 const h=`<header class="city-head"><div><span class="city-code">${escape(c.city_code)}</span><h2>${escape(c.city)}</h2></div><span class="version">${c.questionnaire_version?'Formulario v'+c.questionnaire_version:'Pendiente'}</span></header>`;
 if(labels[c.state])return `<article class="city-card" data-city="${c.id}">${h}<div class="empty"><span class="empty-icon">○</span><h3>${labels[c.state][0]}</h3><p>${labels[c.state][1]}</p><small>No se interpreta como 0 votos.</small></div></article>`;
 const base=c.counts.candidate_base;
 const candidates=c.candidates.map((v,i)=>`<div class="candidate-line"><div class="candidate-title"><span class="swatch" style="--color:${COLORS[i]}"></span><div class="candidate-name">${escape(audience==='internal'?v.real_name:v.code)}${audience==='internal'?`<small>${escape(v.list)}${v.code?' · '+escape(v.code):' · Código por confirmar'}</small>`:''}</div><strong>${percentage(v.count,base)}</strong></div><div class="bar-track"><span style="width:${base?Math.max(0,Math.min(100,v.count/base*100)):0}%;background:${COLORS[i]}"></span></div><div class="candidate-n">${number(v.count)} respuestas</div></div>`).join('');
 const stats=audience==='released'?`<div class="metric"><span>BASE PUBLICADA</span><b>${number(base)}</b></div>`:`<div class="metric"><span>RECIBIDAS</span><b>${number(c.counts.received)}</b></div><div class="metric"><span>ACEPTADAS</span><b>${number(c.counts.accepted)}</b></div><div class="metric"><span>EN REVISIÓN</span><b>${number(c.counts.pending_review)}</b></div>`;
 return `<article class="city-card" data-city="${c.id}">${h}<div class="city-content"><div class="candidate-list">${candidates}</div><div class="chart-area">${donut(c)}<div class="chart-note">${base?'Porcentaje dentro de esta ciudad':'Aún sin base de candidaturas'}</div></div></div><div class="metrics">${stats}<div class="metric"><span>PUNTOS CON DATOS</span><b>${c.coverage.represented_points}<small> / ${c.coverage.configured_points}</small></b></div></div>${c.other_answers?`<div class="other"><span>Blancos <b>${number(c.other_answers.blank)}</b></span><span>Nulos <b>${number(c.other_answers.invalid)}</b></span><span>No revela <b>${number(c.other_answers.undisclosed)}</b></span><span>Rechazos <b>${number(c.other_answers.refused)}</b></span><span>Excluidas <b>${number(c.counts.excluded)}</b></span></div>`:''}<footer class="city-foot"><span>${c.state==='no_data'?'Sin entrevistas recibidas':'Última recepción '+clock(c.last_received)}</span><span>Base = ${number(base)} · sin ponderar</span></footer></article>`;
}
export function selected(data,id){return data.cities.filter(c=>id==='all'||id===c.id);}
export function exportCSV(data,id,demonstration=false){
 validate(data);const cell=v=>'"'+String(v??'').replace(/^[=+@-]/,"'$&").replace(/"/g,'""')+'"';
 const rows=[['PULSO',demonstration?'DATOS FICTICIOS / DEMO':data.private?'PRIVADO / NO DIFUNDIR':'CANAL AUTORIZADO'],['Captura de pantalla estadística, no un archivo vivo',data.server_time],['Ciudad','Código','Nombre interno','Lista interna','Respuestas','Base ciudad','Porcentaje','Estado']];
 for(const c of selected(data,id)){
  if(!c.counts){rows.push([c.city,'','','','','','',c.state]);continue;}
  for(const v of c.candidates)rows.push([c.city,v.code,data.audience==='internal'?v.real_name:'',data.audience==='internal'?v.list:'',v.count,c.counts.candidate_base,percentage(v.count,c.counts.candidate_base),c.state]);
 }
 if(data.audience!=='internal'){rows[2]=['Ciudad','Código','Respuestas','Base ciudad','Porcentaje','Estado'];for(let i=3;i<rows.length;i++)rows[i].splice(2,2);}
 return '\ufeff'+rows.map(r=>r.map(cell).join(',')).join('\r\n');
}
export function exportSVG(data,id,demonstration=false,fresh=true){
 validate(data);const cities=selected(data,id);if(!cities.length)throw new Error('LIVE_NO_DATA');const four=cities.length>1;
 const extra=Math.max(0,...cities.map(c=>c.candidates.length-4)),stepExtra=extra*(four?64:102);
 const W=1920,H=(four?1180:1080)+stepExtra*(four?2:1),margin=48,cols=four?2:1,gap=30,cw=(W-2*margin-gap*(cols-1))/cols,ch=(four?444:720)+stepExtra;
 const txt=(x,y,s,size=24,fill='#c7d6e4',weight=400)=>`<text x="${x}" y="${y}" fill="${fill}" font-size="${size}" font-weight="${weight}">${escape(s)}</text>`;
 let body='';cities.forEach((c,idx)=>{const x=margin+(idx%cols)*(cw+gap),y=208+Math.floor(idx/cols)*(ch+gap);body+=`<g transform="translate(${x} ${y})"><rect width="${cw}" height="${ch}" rx="22" fill="#132434" stroke="#304353"/>`+txt(28,48,c.city,32,'#f5f8fc',750)+txt(cw-132,48,c.city_code,22,'#64dbca',700);
  if(!c.counts){body+=txt(30,150,{codes_pending:'Códigos pendientes',catalog_pending:'Catálogo pendiente',withheld:'Visualización no autorizada',suppressed:'Detalle reservado'}[c.state],29)+txt(30,203,'Sin datos publicables. No equivale a 0 votos.',23);}
  else{const base=c.counts.candidate_base,step=four?64:102,by=four?109:162,barw=four?cw-295:960;
   c.candidates.forEach((v,i)=>{const cy=by+i*step,display=data.audience==='internal'?v.real_name:v.code;body+=`<rect x="28" y="${cy-20}" width="8" height="26" rx="4" fill="${COLORS[i]}"/>`+txt(48,cy,display,data.audience==='internal'?22:27,'#f5f8fc',650)+txt(barw+24,cy,percentage(v.count,base),four?27:38,'#f5f8fc',750)+`<rect x="48" y="${cy+12}" width="${barw-50}" height="6" rx="3" fill="#293d4d"/><rect x="48" y="${cy+12}" width="${base?(barw-50)*v.count/base:0}" height="6" rx="3" fill="${COLORS[i]}"/>`+txt(48,cy+40,number(v.count)+' respuestas',four?17:23);});
   const scale=four?1.03:2.18;body+=`<g transform="translate(${four?cw-233:cw-560} ${four?110:138}) scale(${scale})">${donut(c).replace(/^<svg[^>]*>/,'').replace(/<\/svg>$/,'')}</g>`;
   body+=txt(28,ch-63,'Base de esta ciudad: '+number(base)+' · Formulario v'+c.questionnaire_version,22)+txt(28,ch-28,'Recepción: '+clock(c.last_received)+' · Puntos con datos: '+c.coverage.represented_points+'/'+c.coverage.configured_points,20);
  }body+='</g>';
 });
 const tag=demonstration?'DEMOSTRACIÓN · DATOS FICTICIOS':data.private?'USO INTERNO · NO DIFUNDIR':'CANAL AUTORIZADO · SOLO CÓDIGOS';
 return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" style="font-family:Arial,sans-serif"><rect width="${W}" height="${H}" fill="#081622"/><rect x="48" y="35" width="8" height="58" rx="4" fill="#64dbca"/>${txt(80,86,'BOCA DE URNA',57,'#f5f8fc',800)}${txt(80,137,'ALTO PARANÁ · '+(four?'CUATRO CIUDADES':cities[0].city.toLocaleUpperCase('es')),25)}${txt(1240,74,'CORTE '+clock(data.server_time),31,'#64dbca',700)}${txt(1240,112,fresh?'CAPTURA DEL MONITOR':'CAPTURA SIN ACTUALIZAR',21)}${txt(48,181,tag,21,'#f6cd6a',700)}${body}${txt(48,H-41,'Muestra parcial no ponderada · No es escrutinio ni resultado oficial. Cada ciudad tiene su propio denominador.',22)}</svg>`;
}
