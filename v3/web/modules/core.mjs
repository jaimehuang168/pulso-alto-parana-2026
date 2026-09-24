/** Pure validation: Spanish UI, immutable payloads, no voter identifiers. */
export const CLIENT=30000, VERSION='3.0.0-rc.1';
export const CITIES=[{id:'cde',name:'Ciudad del Este',code:'CDE'},{id:'minga',name:'Minga Guazú',code:'MGA'},{id:'hernandarias',name:'Hernandarias',code:'HER'},{id:'franco',name:'Presidente Franco',code:'PFR'}];
export const OUTCOMES={candidate:'Candidatura',blank:'Voto en blanco',invalid:'Voto nulo',undisclosed:'No revela su voto',refused:'Rechaza la encuesta'};
export const STATE={draft:'Borrador',approved:'Aprobado',open:'Abierto',paused:'En pausa',closed:'Cerrado',pending:'Pendiente',acknowledged:'Confirmado',active:'En servicio',draining:'Solo envío pendiente',ended:'Finalizado',suspended:'Suspendido',retired:'Retirado',running:'En operación',setup:'Preparación',accepted:'Aceptada',pending_review:'En revisión',excluded:'Excluida',published:'Publicada',superseded:'Versión anterior'};
export const ROLES={admin:'Administrador',coordinator:'Coordinador',interviewer:'Encuestador',viewer:'Viewer · solo lectura'};
export const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const uuid=()=>crypto.randomUUID();
export const uuidOK=v=>typeof v==='string'&&/^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i.test(v);
export const city=id=>CITIES.find(d=>d.id===id)?.name||id||'—';
export const num=n=>new Intl.NumberFormat('es-PY').format(Number(n)||0);
export const time=x=>{if(!x)return '—';const d=new Date(x);return Number.isFinite(d.getTime())?new Intl.DateTimeFormat('es-PY',{timeZone:'America/Asuncion',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).format(d):'Hora no válida';};
export const percent=(n,base)=>base>0?new Intl.NumberFormat('es-PY',{maximumFractionDigits:1}).format(n/base*100)+' %':'Sin base';
export function canonical(value){if(value===null||typeof value!=='object')return JSON.stringify(value);if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';}
export async function digest(text){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)))].map(b=>b.toString(16).padStart(2,'0')).join('');}
export function token(){const b=crypto.getRandomValues(new Uint8Array(32));return btoa(String.fromCharCode(...b)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');}
export function safeCell(value){let s=String(value??'');if(/^[\s\u0000-\u001f]*[=+@-]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"';}
export function csv(rows){return '\ufeff'+rows.map(r=>r.map(safeCell).join(',')).join('\r\n');}
export function validateCapture(e,pack,now=Date.now()){
 if(!pack?.assignment||!pack.grant||!pack.questionnaire)throw new Error('V3_NO_ACTIVE_TASK');
 for(const k of ['id','assignment_id','grant_id','questionnaire_id','point_id'])if(!uuidOK(e[k]))throw new Error('V3_INVALID_EVENT');
 if(e.assignment_id!==pack.assignment.id||e.grant_id!==pack.grant.id||e.point_id!==pack.point.id||e.questionnaire_id!==pack.questionnaire.id)throw new Error('V3_ASSIGNMENT_CHANGED');
 if(pack.assignment.status!=='active'||pack.point.state!=='open'||pack.questionnaire.state!=='published')throw new Error('V3_POINT_OR_VERSION_CLOSED');
 if(now>new Date(pack.grant.capture_until).getTime())throw new Error('V3_LEASE_EXPIRED');
 if(!(e.outcome in OUTCOMES)||e.already_voted!==true||e.consent!==(e.outcome!=='refused'))throw new Error('V3_CONSENT_REQUIRED');
 if(e.outcome==='candidate'?!pack.questionnaire.items.some(c=>c.id===e.candidate_id):e.candidate_id!==null)throw new Error('V3_CANDIDATE_VERSION_MISMATCH');
 const s=Date.parse(e.started_at),c=Date.parse(e.captured_at);if(!Number.isFinite(s)||!Number.isFinite(c)||s>c||c-s>7200000)throw new Error('V3_INVALID_TIME');
 if(Object.keys(e).some(k=>!['id','assignment_id','grant_id','questionnaire_id','point_id','started_at','captured_at','candidate_id','outcome','consent','already_voted','geo'].includes(k)))throw new Error('V3_INVALID_EVENT');
 return true;
}
export function assertReceipt(e,r){if(!r||r.response_id!==e.id||!uuidOK(r.receipt_id)||!['accepted','pending_review','excluded'].includes(r.disposition)||!Number.isFinite(Date.parse(r.received_at))||! /^[a-f0-9]{64}$/.test(r.payload_hash||''))throw new Error('V3_RECEIPT_UNCONFIRMED');return r;}
export function allowedPages(role){return {admin:['overview','points','people','tasks','catalog','access','review','paper','imports','exports','settings','guide'],coordinator:['overview','points','people','tasks','paper','guide'],interviewer:['task','capture','queue','records','guide'],viewer:['results','guide']}[role]||[];}
export function hasCap(boot,cap,d,p=null){if(boot?.actor.role==='admin')return true;const now=Date.now();return (boot?.grants||[]).some(g=>g.user_id===boot.actor.user_id&&g.district_id===d&&(!g.point_id||g.point_id===p)&&g.capabilities.includes(cap)&&!g.revoked_at&&Date.parse(g.valid_from)<=now&&Date.parse(g.valid_until)>now);}
const ERROR_TEXT={
 V3_ACCOUNT_DISABLED:['Cuenta no habilitada','Su acceso está desactivado. Contacte a la administración. No cree otra cuenta.'],
 V3_SESSION_REQUIRED:['Vuelva a ingresar','La sesión venció o fue revocada. Los pendientes cifrados permanecen en este dispositivo.'],
 V3_NOT_ACTIVATED:['V3 aún no habilitado','La preparación técnica no es apertura de encuestas. Coordinación debe completar la migración y la aceptación.'],
 V3_UPDATE_REQUIRED:['Actualización requerida','Cierre la tarea, conserve los pendientes y abra la versión aprobada.'],
 V3_SCOPE_DENIED:['Fuera de su alcance','No tiene permiso para este punto o ciudad. No cambie de cuenta ni use permisos compartidos.'],
 V3_ADMIN_ONLY:['Solo administración','Solicite esta operación al responsable central.'],
 V3_VIEWER_RESULTS_PENDING:['Acceso a resultados pendiente','Administración todavía no autorizó las instantáneas para viewers. No se muestran resultados ni datos de encuestadores.'],
 V3_RELOAD_REQUIRED:['Los datos cambiaron','Actualice la pantalla, revise la versión y confirme nuevamente. No se aplicó esta operación.'],
 V3_DEVICE_IN_USE:['Tarea en otro dispositivo','Coordinación debe cerrar o revocar la tarea anterior antes de cambiar de dispositivo.'],
 V3_CANDIDATE_VERSION_MISMATCH:['Candidatura de otra versión','La respuesta no corresponde al formulario autorizado. El pendiente no se modificará automáticamente.'],
 V3_ASSIGNMENT_CHANGED:['Cambió la asignación','Confirme nuevamente el lugar y la versión. No se traslada ninguna respuesta anterior.'],
 V3_LEASE_EXPIRED:['Renueve su autorización','Conéctese para renovar la tarea. No registre entrevistas nuevas fuera del período autorizado.'],
 V3_POINT_OR_VERSION_CLOSED:['Tarea no disponible','El punto está cerrado o la versión fue reemplazada. Conserve y sincronice sus pendientes.'],
 V3_CONSENT_REQUIRED:['Revise la participación','Confirme que ya votó y que acepta participar. Para rechazo no registre preferencia.'],
 V3_IDEMPOTENCY_CONFLICT:['Conflicto de registro','El mismo identificador contiene datos distintos. No se sobrescribió nada; solicite revisión.'],
 V3_TRAINING_REQUIRED:['Falta capacitación','Complete la práctica separada y solicite la aprobación de un coordinador.'],
 V3_TRAINING_RETRY:['Repase la guía','Las respuestas de capacitación no son correctas. La práctica no se incorpora a la muestra.'],
 V3_WORKER_NOT_APPROVED:['Aprobación pendiente','Coordinación debe habilitar a esta persona para trabajar.'],
 V3_POINT_NEEDS_ONE_READY_WORKER:['Falta una persona preparada','Asigne y confirme al menos un encuestador aprobado para este punto.'],
 V3_INVALID_TIME:['Hora inválida','Compruebe fecha y hora del teléfono. No invente ni cambie el momento de una entrevista guardada.'],
 V3_RATE_LIMIT:['Demasiados intentos','Espere antes de reintentar. Verifique el estado de la cuenta si estaba creando un acceso.'],
 V3_ENROLLMENT_CLAIMED:['Código ya tomado','Este código está vinculado a otro intento. Solicite un nuevo acceso a coordinación.'],
 V3_ENROLLMENT_UNAVAILABLE:['Código no disponible','El código venció, fue revocado o ya terminó. Solicite otro; no cree una cuenta pública.'],
 V3_INDEPENDENT_REVIEW_REQUIRED:['Revisión independiente','Otra persona autorizada debe revisar los registros que usted transcribió.'],
 V3_PENDING_ASSIGNMENT_EXISTS:['Ya existe una tarea pendiente','Confirme o cierre la tarea anterior antes de proponer otra.'],
 V3_RECEIPT_UNCONFIRMED:['Recepción sin confirmar','El registro sigue en la cola local. No vuelva a entrevistar ni lo copie con otro identificador.'],
 V3_VAULT_LOCKED:['Archivo local bloqueado','Use la frase de protección de este dispositivo. No borre datos para resolver el acceso.'],
 V3_VAULT_WRONG_KEY:['Frase local incorrecta','No se pudo abrir el archivo cifrado. Los datos no fueron borrados.'],
 V3_LEGACY_DATA_NEEDS_REVIEW:['Datos V2 pendientes de revisión','No se permite una migración automática sobre una jornada V2 iniciada.'],
 V3_CUTOVER_EVIDENCE_REQUIRED:['Falta evidencia de aceptación','Se requieren pruebas y respaldo verificados antes de habilitar V3.'],
 V3_IMPORT_LIMIT:['Archivo fuera de formato','Use PULSO R3, máximo 1.000 filas y sin fórmulas.'],
 V3_UPLOAD_RECOVERY_REQUIRED:['Pendientes de una sesión anterior','Finalice la tarea anterior y solicite Recuperar envío propio. Se conserva la respuesta original y la recepción quedará en revisión.'],
 V3_ACTIVE_TASK_NEEDS_HANDOVER:['Finalice la tarea anterior','Todavía existe una autorización activa. Finalice su tarea o pida a coordinación que cierre la sesión anterior antes de recuperar el envío.'],
 V3_RECOVERY_EXPIRED:['Recuperación fuera de plazo','Conserve la copia cifrada y solicite revisión. No cambie las horas ni vuelva a ingresar esta respuesta.'],
 V3_NO_ACTIVE_TASK:['No hay tarea activa','Confirme y abra una tarea antes de registrar encuestas.']
};
export function feedback(e){const raw=String(e?.message||e||'');let code=(raw.match(/V3_[A-Z0-9_]+/)||[])[0];if(/invalid.login.credentials|invalid_credentials/i.test(raw)||e?.code==='invalid_credentials')return {code:'INGRESO-01',title:'No se pudo iniciar sesión',message:'El código o correo y la contraseña no coinciden.'};if(/network|fetch|timeout|load failed/i.test(raw))return {code:'RED-01',title:'No se pudo conectar',message:'No se confirma si una operación llegó al servidor. Conserve los pendientes y use el mismo intento al reanudar.'};code=code||'V3_OPERATION_FAILED';if(code==='V3_INVITE_CLAIMED')code='V3_ENROLLMENT_CLAIMED';if(code==='V3_INVITE_UNAVAILABLE')code='V3_ENROLLMENT_UNAVAILABLE';let text=ERROR_TEXT[code]||['Operación no completada','No se confirmó la operación. Informe esta referencia a coordinación; no borre datos ni repita altas con otro código.'];return {code,title:text[0],message:text[1]};}
export function download(text,name,type='text/plain;charset=utf-8'){const blob=text instanceof Blob?text:new Blob([text],{type});const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),2000);}

/** Private TXT avoids spreadsheet coercion of a leading minus in a generated password. */
export function credentialText(c){if(!c||typeof c.code!=="string"||typeof c.password!=="string"||/[\r\n]/.test(c.code+c.password))throw new Error("V3_INVALID_CREDENTIAL");return "PULSO · CREDENCIAL PRIVADA\nCódigo: "+c.code+"\nContraseña: "+c.password+"\nNo publicar ni compartir con otras personas.\n";}
