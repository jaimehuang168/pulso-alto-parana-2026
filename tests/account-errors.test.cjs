'use strict';
const test=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const start=app.indexOf('function safeAccountText('),end=app.indexOf('function showCredentials(',start);
assert(start>=0&&end>start,'Account diagnostics functions are missing');
function setup(result,options={}){
 const calls=[];let refreshes=0;
 const session={access_token:'unit-test-session-token',user:{id:'qa-admin'},expires_at:Date.now()/1000+3600};
 const sb={auth:{getSession:async()=>({data:{session:options.noSession?null:options.expired?{...session,expires_at:1}:options.wrongUser?{...session,user:{id:'other'}}:session},error:null}),refreshSession:async()=>{refreshes++;return{data:{session:options.refreshFails?null:{...session,access_token:'renewed-test-session'}},error:options.refreshFails?new Error('expired'):null};}},functions:{invoke:async(name,args)=>{calls.push({name,args});if(options.throwError)throw options.throwError;return typeof result==='function'?result():result;}}};
 const S={profile:{id:'qa-admin'},accountBusy:false};const scope={S,client:async()=>sb,Date,Error,Number,String,Object};
 vm.createContext(scope);vm.runInContext(app.slice(start,end),scope);
 return{...scope,calls,refreshes:()=>refreshes};
}
function http(status,payload){return {error:{name:'FunctionsHttpError',context:new Response(JSON.stringify(payload),{status,headers:{'Content-Type':'application/json'}})},data:null};}
test('account: success forwards an explicit user token once',async()=>{const s=setup({data:{credential:{code:'VIEW-QA001'}},error:null});assert.equal((await s.edge({action:'create-account'})).credential.code,'VIEW-QA001');assert.equal(s.calls.length,1);assert.equal(s.calls[0].args.headers.Authorization,'Bearer unit-test-session-token');assert.equal(s.S.accountBusy,false);});
test('account: missing session makes no function request',async()=>{const s=setup(null,{noSession:true});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_SESSION');assert.equal(s.calls.length,0);assert.equal(s.S.accountBusy,false);});
test('account: different user session is not sent',async()=>{const s=setup(null,{wrongUser:true});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_SESSION');assert.equal(s.calls.length,0);});
test('account: expired session is refreshed before one write',async()=>{const s=setup({data:{ok:true},error:null},{expired:true});await s.edge({});assert.equal(s.refreshes(),1);assert.equal(s.calls.length,1);assert.equal(s.calls[0].args.headers.Authorization,'Bearer renewed-test-session');});
test('account: failed refresh does not send a write',async()=>{const s=setup(null,{expired:true,refreshFails:true});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_SESSION');assert.equal(s.calls.length,0);});
for(const [status,payload,expected] of [[401,{message:'Invalid JWT'},'Invalid JWT'],[403,{error:'Solo coordinación autorizada.'},'Solo coordinación'],[404,{message:'Function not found'},'Function not found'],[409,{error:'Este código ya existe.'},'Este código ya existe.'],[429,{message:'Too many requests'},'Too many requests'],[500,{error:'Falta configuración segura de servidor.'},'Falta configuración']]){
 test('account: preserves safe HTTP '+status+' response without retry',async()=>{const s=setup(http(status,payload));await assert.rejects(s.edge({action:'create-account'}),e=>e.code==='ACCOUNT_HTTP_'+status&&e.message.includes(expected));assert.equal(s.calls.length,1);assert.equal(s.S.accountBusy,false);});
}
test('account: CORS or fetch failure is not mislabelled HTTP 401',async()=>{const s=setup({data:null,error:{name:'FunctionsFetchError'}});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_CONNECTION');assert.equal(s.calls.length,1);});
test('account: thrown network failure is shown without retry',async()=>{const s=setup(null,{throwError:new TypeError('Failed to fetch')});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_CONNECTION');assert.equal(s.calls.length,1);});
test('account: invalid response remains unconfirmed',async()=>{const s=setup({data:null,error:null});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_RESPONSE');});
test('account: unreadable HTTP body retains status',async()=>{const s=setup({data:null,error:{context:new Response('<html>upstream</html>',{status:502})}});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_HTTP_502'&&!e.message.includes('<html>'));});
test('account: sensitive token and key text is redacted',async()=>{const s=setup(http(500,{message:'sb_secret_privatevalue Bearer eyJabc.payload.signature'}));await assert.rejects(s.edge({}),e=>!e.message.includes('privatevalue')&&!e.message.includes('eyJabc'));});
test('account: error body with HTTP 200 is not treated as success',async()=>{const s=setup({data:{error:'Solicitud rechazada'},error:null});await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_RESPONSE');});
test('account: concurrent click sends only one request',async()=>{let done;const s=setup(()=>new Promise(resolve=>{done=resolve;}));const first=s.edge({});await new Promise(resolve=>setImmediate(resolve));await assert.rejects(s.edge({}),e=>e.code==='ACCOUNT_BUSY');done({data:{ok:true},error:null});await first;assert.equal(s.calls.length,1);});
test('account: persistent UI error uses textContent',()=>{assert(app.includes("box.textContent='Diagnóstico de cuentas A1"));assert(!app.includes('box.innerHTML='));});
