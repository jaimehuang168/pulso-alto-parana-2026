const test=require('node:test'),assert=require('node:assert/strict');
const modulePromise=import('../web/pruebas/storage-diagnostic.mjs');
const fixedId='22222222-2222-4222-8222-222222222222';
// Explicit fault-injection fixture. This is not an actual browser or a phone test.
function factory(options={}){
 const touched=[],later=(fn)=>setTimeout(fn,0),error=(name)=>({name,message:'PRIVATE_TOKEN_AND_DATA_MUST_NOT_LEAK'});
 let storage;
 const db={objectStoreNames:{contains:n=>n==='probe'},createObjectStore(){if(options.schema)throw error(options.schema);},close(){touched.push(['close']);if(options.close)throw error(options.close);},transaction(store,mode){
  touched.push(['transaction',store,mode]);const stage=mode==='readwrite'?'write':'read';
  if(options[stage+'Throw'])throw error(options[stage+'Throw']);
  const tx={error:null,abort(){tx.onabort?.({type:'abort',target:tx});},objectStore:()=>({put(value,key){return req(value);},get(key){return req();}})};
  function req(value){const r={result:undefined,error:null};later(()=>{
   if(options[stage+'Hang'])return;
   if(options[stage]){r.error=error(options[stage]);r.onerror?.({type:'error',target:r});tx.onerror?.({type:'error',target:r});tx.error=r.error;tx.onabort?.({type:'abort',target:tx});return;}
   if(stage==='write')storage=value;r.result=stage==='read'?(options.mismatch?'WRONG':storage):undefined;r.onsuccess?.({type:'success',target:r});
   later(()=>{if(options[stage+'Abort'])tx.onabort?.({type:'abort',target:tx});else tx.oncomplete?.({type:'complete',target:tx});});
  });return r;}
  return tx;
 }};
 const f={touched,open(name,version){touched.push(['open',name]);if(options.openThrow)throw error(options.openThrow);const r={result:db,error:null,transaction:{abort(){}}};
  if(options.openHang)return r;
  later(()=>{if(options.open){r.error=error(options.open);r.onerror?.({type:'error',target:r});return;}if(options.openBlocked){r.onblocked?.({type:'blocked',target:r});return;}r.onupgradeneeded?.({type:'upgradeneeded',target:r});if(!options.schema)r.onsuccess?.({type:'success',target:r});});return r;
 },deleteDatabase(name){touched.push(['delete',name]);if(options.cleanupThrow)throw error(options.cleanupThrow);const r={error:null};later(()=>{if(options.cleanupHang)return;if(options.cleanup){r.error=error(options.cleanup);r.onerror?.({type:'error',target:r});}else if(options.cleanupBlocked)r.onblocked?.({type:'blocked',target:r});else r.onsuccess?.({type:'success',target:r});});return r;}};
 return f;
}
async function run(o={}){const m=await modulePromise,f=factory(o),r=await m.diagnoseStorage({factory:f,id:fixedId,timeoutMs:35});return {m,f,r};}
test('IDB success requires both write and read transaction completion and separate cleanup',async()=>{const {r,f}=await run();assert.equal(r.readwrite_status,'pass');assert.equal(r.cleanup_status,'pass');assert(r.stages.every(x=>x.status==='pass'));assert.equal(r.failure_stage,null);const names=f.touched.filter(x=>x[0]==='open'||x[0]==='delete').map(x=>x[1]);assert(names.every(n=>n==='pulso-readonly-probe-v2-'+fixedId));});
for(const [stage,option,name] of [['open','openThrow','SecurityError'],['open','open','UnknownError'],['schema','schema','ConstraintError'],['write','write','QuotaExceededError'],['write','writeThrow','TransactionInactiveError'],['read','read','NotFoundError'],['read','readThrow','InvalidStateError']])test('IDB retains '+stage+' / '+name,async()=>{const {r}=await run({[option]:name});assert.equal(r.failure_stage,stage);assert.equal(r.error_name,name);assert.equal(r.readwrite_status,'fail');assert.equal(r.cleanup_status,'pass');assert(!JSON.stringify(r).includes('PRIVATE'));});
for(const stage of ['write','read'])test('IDB '+stage+' request success followed by transaction abort is NOT a pass',async()=>{const {r}=await run({[stage+'Abort']:true});assert.equal(r.failure_stage,stage);assert.equal(r.error_name,'AbortError');assert.equal(r.readwrite_status,'fail');});
test('IDB readback mismatch reports read verification separately',async()=>{const {r}=await run({mismatch:true});assert.equal(r.error_name,'ProbeReadbackMismatchError');assert.equal(r.failure_stage,'read');});
for(const [option,name] of [['cleanup','UnknownError'],['cleanupThrow','SecurityError']])test('IDB '+option+' error does not turn successful read/write into failure',async()=>{const {r,m}=await run({[option]:name});assert.equal(r.readwrite_status,'pass');assert.equal(r.cleanup_status,'fail');assert.equal(r.stages.at(-1).error_name,name);const [rw,clean]=m.storageChecks(r);assert.equal(rw.status,'pass');assert.equal(clean.status,'fail');});
test('IDB blocked cleanup stays blocked while read/write pass',async()=>{const {r}=await run({cleanupBlocked:true});assert.equal(r.readwrite_status,'pass');assert.equal(r.cleanup_status,'blocked');assert.equal(r.stages.at(-1).error_name,'BlockedError');});
test('IDB blocked open has a named stage and does not wait indefinitely',async()=>{const {r}=await run({openBlocked:true});assert.equal(r.failure_stage,'open');assert.equal(r.error_name,'BlockedError');});
test('IDB initial write error is not overwritten by failing cleanup',async()=>{const {r}=await run({write:'QuotaExceededError',cleanup:'UnknownError'});assert.equal(r.error_name,'QuotaExceededError');assert.equal(r.stages.at(-1).error_name,'UnknownError');assert.equal(r.cleanup_status,'fail');});
test('IDB close failure is independently visible',async()=>{const {r}=await run({close:'InvalidStateError'});assert.equal(r.readwrite_status,'pass');assert.equal(r.stages.find(x=>x.stage==='close').error_name,'InvalidStateError');assert.equal(r.cleanup_status,'fail');});
for(const stage of ['open','write','read','cleanup'])test('IDB '+stage+' timeout returns a bounded, exact diagnosis',async()=>{const {r}=await run({[stage+'Hang']:true});const x=r.stages.find(x=>x.stage===stage);assert.equal(x.error_name,'ProbeTimeoutError');assert.equal(x.event_type,'timeout');assert.equal(x.status,'fail');});
test('IDB unavailable factory is not mistaken for quota or private browsing',async()=>{const m=await modulePromise,r=await m.diagnoseStorage({factory:null,id:fixedId});assert.equal(r.error_name,'NotSupportedError');assert.equal(r.stages.at(-1).status,'untested');});
test('IDB native request errors are extracted from events, never raw messages',async()=>{const m=await modulePromise;assert.equal(m.nativeError({target:{error:{name:'QuotaExceededError',message:'SECRET'}}}),'QuotaExceededError');assert.equal(m.nativeError({type:'error'}),'ErrorDetailsUnavailable');assert.equal(m.nativeError({name:'PRIVATE_DATA'}),'ErrorDetailsUnavailable');assert.equal(m.nativeError({get target(){throw Error('SECRET');}}),'ErrorDetailsUnavailable');});
test('IDB diagnostic export discards arbitrary properties and preserves both result groups',async()=>{const {m,r}=await run({write:'DataError',cleanup:'SecurityError'});r.password='PRIVATE';r.stages[2].message='PRIVATE';const cleaned=m.sanitizeStorage(r);assert(!JSON.stringify(cleaned).includes('PRIVATE'));assert.equal(cleaned.error_name,'DataError');assert.equal(cleaned.stages.at(-1).error_name,'SecurityError');assert.equal(cleaned.existing_app_databases_accessed,false);});
test('IDB refuses arbitrary database names',async()=>{const m=await modulePromise,f=factory();const r=await m.diagnoseStorage({factory:f,id:'pulso-v3-encrypted'});assert.equal(f.touched.length,0);assert.equal(r.readwrite_status,'fail');});
test('Read-only export preserves sanitized diagnostic but does not certify a phone',async()=>{const {r}=await run(),core=await import('../web/pruebas/core.mjs');const data=core.record([],{}, {},false,r);assert.equal(data.schema,'pulso-pruebas-2');assert.equal(data.storage_diagnostic.readwrite_status,'pass');assert.equal(data.production_activation_approved,false);assert.equal(data.automated_physical_certification,false);});
