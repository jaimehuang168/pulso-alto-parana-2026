/**
 * Bounded, isolated IndexedDB diagnostic. Never reads or clears a Pulso outbox.
 * Only generated disposable databases are touched. Request success is NOT a commit.
 * Native error names are retained; arbitrary error messages/paths/data are not exported.
 */
export const STORAGE_SCHEMA='pulso-storage-diagnostic-2';
export const STAGES=Object.freeze(['open','schema','write','read','close','cleanup']);
const NAMES=new Set(['Error','TypeError','ReferenceError','RangeError','SecurityError','InvalidStateError','UnknownError','QuotaExceededError','AbortError','NotFoundError','ConstraintError','DataError','DataCloneError','ReadOnlyError','TransactionInactiveError','VersionError','InvalidAccessError','NotSupportedError','SyntaxError','TimeoutError','OperationError','NotAllowedError','InvalidModificationError','BlockedError','ProbeTimeoutError','ProbeReadbackMismatchError','ErrorDetailsUnavailable']);
const EVENTS=new Set(['error','abort','blocked','timeout','exception','verification','none']);
const pick=(x,k)=>{try{return x?.[k];}catch{return undefined;}};
export function nativeError(e,fallback='ErrorDetailsUnavailable'){
 const target=pick(e,'target');
 const nested=pick(target,'error')||pick(e,'error')||e;
 const name=pick(nested,'name');
 return NAMES.has(name)?name:NAMES.has(fallback)?fallback:'ErrorDetailsUnavailable';
}
const problem=(name,event_type='exception')=>({name,event_type});
export function sanitizeStorage(value){
 if(!value||value.schema!==STORAGE_SCHEMA||!Array.isArray(value.stages))return null;
 const stages=STAGES.map(stage=>{
  const x=value.stages.find(r=>r?.stage===stage)||{};
  return {stage,status:['pass','fail','blocked','untested'].includes(x.status)?x.status:'untested',
   error_name:NAMES.has(x.error_name)?x.error_name:null,event_type:EVENTS.has(x.event_type)?x.event_type:'none',
   duration_ms:Number.isFinite(x.duration_ms)?Math.max(0,Math.min(120000,Math.round(x.duration_ms))):0};
 });
 const primary=stages.filter(r=>['open','schema','write','read'].includes(r.stage));
 const failure=primary.find(r=>r.stage==='schema'&&r.status==='fail')||primary.find(r=>r.status==='fail'||r.status==='blocked');
 const close=stages.find(r=>r.stage==='close'),cleanup=stages.find(r=>r.stage==='cleanup');
 return {schema:STORAGE_SCHEMA,readwrite_status:failure?'fail':primary.every(r=>r.status==='pass')?'pass':'untested',
  cleanup_status:cleanup.status==='pass'&&close.status==='fail'?'fail':cleanup.status,
  failure_stage:failure?.stage||null,error_name:failure?.error_name||null,
  stages,synthetic_data_only:true,existing_app_databases_accessed:false,
  physical_storage_durability_certified:false};
}
export async function diagnoseStorage({factory,timeoutMs=6000,now=()=>performance.now(),id}={}){
 const rows=[];let db=null,openAttempted=false,source=factory;
 const time=()=>now();
 const result=(stage,status,started,error=null,event_type='none')=>{
  const r={stage,status,error_name:error?nativeError(error):null,event_type,duration_ms:time()-started};
  const i=rows.findIndex(x=>x.stage===stage);if(i<0)rows.push(r);else rows[i]=r;return r;
 };
 const step=async(stage,fn)=>{const started=time();try{await fn();result(stage,'pass',started);return true;}catch(e){result(stage,pick(e,'event_type')==='blocked'?'blocked':'fail',started,e,pick(e,'event_type')||'exception');return false;}};
 const wait=(setup,onTimeout=()=>{})=>new Promise((resolve,reject)=>{
  let done=false;
  const timer=setTimeout(()=>{if(done)return;done=true;try{onTimeout();}catch{}reject(problem('ProbeTimeoutError','timeout'));},timeoutMs);
  const end=(error=null)=>{if(done)return;done=true;clearTimeout(timer);error?reject(error):resolve();};
  const bad=(e,type='error',fallback='ErrorDetailsUnavailable')=>end(problem(nativeError(e,fallback),type));
  try{setup(end,bad,()=>done);}catch(e){bad(e,'exception');}
 });
 // IDs are generated internally in production. Tests may inject a valid UUID, never a DB name.
 const suffix=id||globalThis.crypto?.randomUUID?.();
 if(!/^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i.test(suffix||'')){
  result('open','fail',time(),problem('NotSupportedError'),'exception');return sanitizeStorage({schema:STORAGE_SCHEMA,stages:rows});
 }
 const name='pulso-readonly-probe-v2-'+suffix;
 const opened=await step('open',async()=>{
  if(source===undefined)source=globalThis.indexedDB;
  if(!source||typeof source.open!=='function'||typeof source.deleteDatabase!=='function')throw problem('NotSupportedError');
  let request;
  await wait((end,bad,done)=>{
   openAttempted=true;request=source.open(name,1);
   request.onblocked=e=>bad(e,'blocked','BlockedError');
   request.onupgradeneeded=()=>{
    if(done()){try{request.transaction?.abort();}catch{}return;}
    const started=time();
    try{request.result.createObjectStore('probe');result('schema','pass',started);}
    catch(e){result('schema','fail',started,e,'exception');try{request.transaction?.abort();}catch{}bad(e,'exception');}
   };
   request.onerror=e=>bad(e,'error');
   request.onsuccess=()=>{
    if(done()){
     // Timeout cannot cancel IDB open. Close a late connection and clean only this exact test DB.
     try{request.result.close();const late=source.deleteDatabase(name);late.onerror=()=>{};late.onblocked=()=>{};}catch{}
     return;
    }
    db=request.result;db.onversionchange=()=>db.close();
    if(!rows.some(r=>r.stage==='schema')){
     const started=time();if(db.objectStoreNames.contains('probe'))result('schema','pass',started);
     else{result('schema','fail',started,problem('NotFoundError'),'verification');bad(problem('NotFoundError'),'verification');return;}
    }
    end();
   };
  },()=>{try{request?.transaction?.abort();}catch{}});
 });
 const transaction=async(mode)=>{
  let tx,request,found,requestSucceeded=false,firstError=null;
  await wait((end,bad)=>{
   tx=db.transaction('probe',mode);
   tx.onerror=e=>{if(!firstError)firstError=problem(nativeError(e),'error');};
   tx.onabort=e=>bad(firstError||e,'abort','AbortError');
   tx.oncomplete=()=>{
    if(!requestSucceeded){bad(problem('ErrorDetailsUnavailable'),'verification');return;}
    if(mode==='readonly'&&found!=='SYNTHETIC_ONLY'){bad(problem('ProbeReadbackMismatchError'),'verification');return;}
    end();
   };
   request=mode==='readwrite'?tx.objectStore('probe').put('SYNTHETIC_ONLY','check'):tx.objectStore('probe').get('check');
   request.onerror=e=>{firstError=problem(nativeError(e),'error');bad(firstError,'error');};
   request.onsuccess=()=>{requestSucceeded=true;if(mode==='readonly')found=request.result;};
  },()=>{try{tx?.abort();}catch{}});
 };
 try{
  if(opened&&rows.find(r=>r.stage==='schema')?.status==='pass'){
   if(await step('write',()=>transaction('readwrite')))await step('read',()=>transaction('readonly'));
  }
 }finally{
  // Separate results: cleanup failure must never replace the original read/write error.
  if(db)await step('close',()=>{db.close();});
  if(openAttempted&&source)await step('cleanup',()=>wait((end,bad)=>{
   const request=source.deleteDatabase(name);
   request.onsuccess=()=>end();request.onerror=e=>bad(e,'error');request.onblocked=e=>bad(e,'blocked','BlockedError');
  }));
 }
 return sanitizeStorage({schema:STORAGE_SCHEMA,stages:rows});
}
export function storageChecks(report){
 const d=sanitizeStorage(report);if(!d)return [];
 const rw=d.stages.filter(r=>['open','schema','write','read'].includes(r.stage));
 const failure=d.stages.find(r=>r.stage===d.failure_stage);
 const cleanup=d.stages.find(r=>r.stage==='cleanup'),close=d.stages.find(r=>r.stage==='close');
 const cleanProblem=close.status==='fail'?close:cleanup;
 return [
  {id:'browser.indexeddb',status:d.readwrite_status,
   detail:d.readwrite_status==='pass'?'Apertura, esquema, escritura confirmada y lectura confirmada: conformes. Limpieza evaluada por separado.':`Etapa: ${d.failure_stage||'no ejecutada'} · Error: ${d.error_name||'no disponible'} · Evento: ${failure?.event_type||'none'}`,
   duration_ms:rw.reduce((n,r)=>n+r.duration_ms,0)},
  {id:'browser.indexeddb.cleanup',status:d.cleanup_status,
   detail:d.cleanup_status==='pass'?'Base temporal de diagnóstico eliminada. No se abrieron ni borraron bases de encuestas.':`Etapa: ${cleanProblem.stage} · Error: ${cleanProblem.error_name||'no disponible'} · Evento: ${cleanProblem.event_type}. Solo la base temporal de diagnóstico.`,
   duration_ms:close.duration_ms+cleanup.duration_ms}
 ];
}
