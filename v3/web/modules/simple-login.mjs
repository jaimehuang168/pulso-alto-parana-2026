import {esc as E,CITIES,STATE,time} from './core.mjs';
export const SIMPLE_VERSION=15;
export function hasSimple(boot){return boot?.simple_login_version===SIMPLE_VERSION;}
export function generatedPassword(){
 const alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
 const bytes=crypto.getRandomValues(new Uint8Array(64));let out='';
 for(const n of bytes){if(n<Math.floor(256/alphabet.length)*alphabet.length)out+=alphabet[n%alphabet.length];if(out.length===20)return out;}
 return generatedPassword();
}
const option=(value,label)=>`<option value="${E(value)}">${E(label)}</option>`;
export function accountFields(){
 return `<p>Cree una cuenta individual. Esta acción autoriza a la persona para trabajar; no abre la jornada ni los puntos.</p>
 <label>Nombre del encuestador<input name="display_name" required maxlength="100" autocomplete="off"></label>
 <label>Código de acceso<input name="code" required pattern="ENC-[A-Z0-9][A-Z0-9-]{2,30}" maxlength="35" placeholder="ENC-CDE-001" autocapitalize="characters" autocomplete="off"></label>
 <label>Contraseña individual<input name="password" type="password" required minlength="16" maxlength="128" autocomplete="new-password"></label>
 <div class="actions"><button type="button" data-action="simple-generate">Generar contraseña</button><button type="button" data-action="simple-password-toggle">Mostrar / ocultar</button></div>
 <p class="inline-note">Al menos 16 caracteres. Entregue la contraseña solo a esta persona.</p>
 <label>Ciudad<select name="district_id" id="simple-city" required>${option('','Seleccione una ciudad')}${CITIES.map(c=>option(c.id,c.name)).join('')}</select></label>
 <label>Local de votación<select id="simple-station">${option('','Asignar después')}</select></label>
 <label>Punto de encuesta<select name="point_id" id="simple-point">${option('','Asignar después')}</select></label>
 <p class="inline-note">Sin punto, la cuenta se crea y espera la asignación. Cada persona verá únicamente el formulario de su tarea.</p>`;
}
export function updateOptions(boot,changed){
 const city=document.querySelector('#simple-city'),station=document.querySelector('#simple-station'),point=document.querySelector('#simple-point');
 if(!city||!station||!point)return;
 if(changed==='city')station.innerHTML=option('','Asignar después')+boot.stations.filter(s=>s.district_id===city.value).map(s=>option(s.id,s.name)).join('');
 point.innerHTML=option('','Asignar después')+boot.points.filter(p=>p.station_id===station.value).map(p=>option(p.id,p.label)).join('');
}
export function waiting(S){
 const messages={waiting_setup:'La empresa todavía está preparando el acceso.',waiting_admin:'La administración debe habilitar su trabajo.',
 waiting_assignment:'Espere la asignación de su administrador.',waiting_start:'La jornada todavía no está abierta para encuestar.',
 waiting_point:'Su punto de encuesta todavía no está abierto.',waiting_questionnaire:'La empresa debe publicar el formulario de su ciudad.',
 expired:'Conecte a Internet para continuar. Sus respuestas guardadas se conservan.',offline:'No hay conexión. Conserve este teléfono y espere a recuperar Internet.'};
 const state=S.simpleState||'waiting_assignment';
 return `<section class="card"><h1>Su cuenta está lista</h1><p>${E(messages[state]||'No se pudo preparar su tarea. Avise a la administración.')}</p>
 <p>No necesita configurar el teléfono ni crear otra contraseña.</p><div class="actions"><button data-action="simple-retry" class="primary">Actualizar mi tarea</button><a class="button" href="manual-simple.html" target="_blank" rel="noopener">Ver ayuda</a></div></section>`;
}
export function taskInfo(S){
 const p=S.pack;
 if(!p)return waiting(S);
 return `<section class="card"><h1>Mi lugar de trabajo</h1><p><strong>${E(p.station?.name||'')}</strong><br>${E(p.point.label)}</p>
 <p>Formulario: ${E(p.questionnaire.contest)} · versión ${E(p.questionnaire.version)}</p>
 <p>La tarea se prepara y renueva automáticamente mientras haya conexión y autorización.</p>
 <div class="actions"><button class="primary" data-action="nav" data-id="capture">Volver a encuestar</button><button data-action="finish-my-task" data-id="${E(p.assignment.id)}">Finalizar mi tarea</button></div></section>`;
}
export function legacyUnlock(S,V){
 return `<div class="login"><section class="intro"><div class="brand"><img src="icon.svg" alt="">pulso</div><h1>Conservar datos anteriores</h1><p>Este teléfono tiene un archivo protegido de la versión anterior. No se ha borrado.</p></section><section class="card"><h2>Recuperación por única vez</h2>${V.notice(S.error)}
 <p>Escriba la frase que usaba antes. No cree una nueva: necesitamos copiar sus registros anteriores sin perderlos.</p>
 <form id="vault-form"><label>Frase anterior<input type="password" name="phrase" minlength="12" required autocomplete="off"></label><button class="primary wide" type="submit">Conservar y continuar</button></form>
 <p>Después de esta copia no se pedirá una segunda frase para el uso normal. Si no la recuerda, contacte al administrador; no elimine los datos.</p>
 <button data-action="logout">Salir</button></section></div>`;
}
