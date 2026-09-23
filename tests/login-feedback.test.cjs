'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const start=source.indexOf('function loginFeedback('),end=source.indexOf('function loginFeedbackHTML()');assert(start>=0&&end>start);
const context={};vm.runInNewContext(source.slice(start,end)+';this.classify=loginFeedback;',context);const map=context.classify;
const examples=[
 ['disabled bootstrap',{code:'42501',message:'Cuenta no habilitada o sin perfil asignado.'},'access','ACCESO-403'],
 ['missing active flag',{message:'Cuenta no habilitada.'},'access','ACCESO-403'],
 ['invalid password',{code:'invalid_credentials'},'login','INGRESO-01'],
 ['email confirmation',{code:'email_not_confirmed'},'login','CORREO-01'],
 ['auth blocked',{code:'user_banned'},'login','ACCESO-403'],
 ['rate limit',{status:429},'login','ESPERA-429'],
 ['fetch network',{name:'AuthRetryableFetchError'},'login','RED-01'],
 ['timeout',{name:'TimeoutError'},'access','RED-01'],
 ['offline network',{message:'Failed to fetch'},'access','RED-01'],
 ['expired session',{code:'PGRST301',status:401},'access','SESION-401'],
 ['missing connection',{message:'Configure el servidor antes de iniciar sesión.'},'login','CONFIG-01'],
 ['unknown auth error',{message:'unknown'},'login','INGRESO-ERROR'],
 ['unknown data error',{message:'unknown'},'access','ACCESO-ERROR']
];
for(const [name,error,stage,expected] of examples)test('login notice: '+name,()=>{const n=map(error,stage);assert.equal(n.code,expected);assert.ok(n.title.length>5&&n.message.length>10&&n.next.length>10);});
test('server payload and credentials never included',()=>{const raw='PASSWORD_TEST_PRIVATE sb_secret_test PRIVATE_TOKEN <script>alert(1)</script>';for(const stage of ['login','access'])assert(!JSON.stringify(map({message:raw},stage)).includes('PRIVATE'));});
test('generic auth failure is not labelled deactivated',()=>assert.equal(map({status:403,message:'unknown'},'login').code,'INGRESO-ERROR'));
test('persistent alert is in login form area',()=>{assert(source.includes('id="login-feedback"'));assert(source.includes('role="alert" aria-atomic="true"'));assert(source.includes('${loginFeedbackHTML()}<form id="login-form"'));});
test('error path preserves outbox and other sessions',()=>{const helper=source.slice(source.indexOf('function showLoginFeedback('),source.indexOf('window.visualViewport?.'));assert(!/store\.(?:delete|clear)|indexedDB\.deleteDatabase|localStorage\.clear|signOut/.test(helper));});
test('mobile toast removes inherited translation',()=>{const css=fs.readFileSync(path.join(__dirname,'../web/styles.css'),'utf8');const last=css.slice(css.indexOf('/* L2：'));assert(last.includes('width:auto;max-width:none;transform:none;'));assert(last.includes('.login-feedback p{font-size:18px}'));});
