/** Present only the current authenticated/local identity; never grant permissions here. */
import {esc} from './core.mjs';
const clean=value=>typeof value==='string'?value.replace(/[\u0000-\u001f\u007f]/g,' ').trim():'';
export function identityData(actor){
 if(!actor||typeof actor!=='object'||!actor.user_id)return null;
 const code=clean(actor.code),name=clean(actor.display_name)||code||'Nombre no configurado';
 return {name,code};
}
export function sessionIdentity(actor,offline=false){
 const p=identityData(actor);if(!p)return '';
 return `<div class="current-session" data-session-identity aria-label="Persona conectada"><span class="session-avatar" aria-hidden="true">${esc(Array.from(p.name)[0].toLocaleUpperCase('es'))}</span><div><small>${offline?'Cuenta local · sin conexión':'Sesión iniciada'}</small><strong data-session-name>${esc(p.name)}</strong>${p.code&&p.code!==p.name?`<span data-session-code>${esc(p.code)}</span>`:''}</div></div>`;
}
