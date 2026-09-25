"""Actual Chromium UI/storage; explicit fake Auth/API fixtures, never production credentials."""
import json,pathlib,functools,http.server,threading,contextlib,os,subprocess
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parents[1]/'web';OUT=pathlib.Path(os.environ.get('PULSO_TEST_EVIDENCE',str(ROOT.parent/'tests/artifacts/readiness')));OUT.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 extensions_map={**http.server.SimpleHTTPRequestHandler.extensions_map,'.mjs':'text/javascript'}
 def log_message(self,*a):pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',8048),functools.partial(Quiet,directory=str(ROOT)));threading.Thread(target=s.serve_forever,daemon=True).start()
checks=[]
def check(name,value):
 assert value,name
 checks.append({'name':name,'pass':True})
config={'supabaseUrl':'https://original-project.supabase.co','publishableKey':'sb_publishable_QA_PUBLIC_ONLY','simulation':False}
fixture=r'''window.__sdkCalls=[];window.supabase={createClient:(url,key,opts)=>{window.__sdkCalls.push({type:'client',url,opts});return {auth:{getSession:async()=>({data:{session:null}}),signInWithPassword:async v=>{window.__sdkCalls.push({type:'login',hasPassword:!!v.password});return {data:{session:{user:{id:'FAKE'}}},error:null}},signOut:async v=>{window.__sdkCalls.push({type:'logout',scope:v.scope});return {error:null}}},realtime:{disconnect:async()=>{}},rpc:(name,args)=>{window.__sdkCalls.push({type:'rpc',name});let data=name==='v3_bootstrap'?{actor:{role:'admin'}}:name==='v3_preflight'?{operation_mode:'v2',migrations:[4,5,6,7,8,9,10,11],legacy_responses:0,v3_responses:0,legacy_actor_drift:0,secret:'PRIVATE_MARKER'}:name==='v3_live_admin_state'?{operation:{phase:'setup'},cities:[{},{},{},{}]}:{audience:'internal',cities:[{candidates:[{name:'PRIVATE_CANDIDATE_MARKER',id:'PRIVATE_UUID_MARKER',count:99}]}]};return {abortSignal:async()=>({data,error:window.__denyBootstrap&&name==='v3_bootstrap'?{code:'42501',message:'V3_ACCOUNT_DISABLED'}:null})}}}}};'''
subprocess.run(['node','--check','--input-type=commonjs'],input=fixture,text=True,check=True)
with sync_playwright() as p:
 browser=p.chromium.launch(**({'executable_path':os.environ['PULSO_TEST_BROWSER']} if os.environ.get('PULSO_TEST_BROWSER') else {}))
 ctx=browser.new_context(viewport={'width':390,'height':844},accept_downloads=True)
 ctx.route('**/v3/config.js',lambda r:r.fulfill(body='window.PULSO_V3_CONFIG='+json.dumps(config)+';',content_type='application/javascript'))
 ctx.route('**/vendor/supabase.js',lambda r:r.fulfill(body=fixture,content_type='application/javascript'))
 requests=[]
 def net(r):
  req=r.request;requests.append({'method':req.method,'url':req.url,'body':req.post_data})
  h={'Access-Control-Allow-Origin':'http://127.0.0.1:8048','Access-Control-Allow-Headers':'apikey,content-type','Access-Control-Allow-Methods':'POST,OPTIONS'}
  if req.method=='OPTIONS':r.fulfill(status=204,headers=h);return
  body={'code':'42501'} if '/rest/v1/' in req.url else {'error':'V3_SESSION_REQUIRED'}
  r.fulfill(status=401,body=json.dumps(body),content_type='application/json',headers=h)
 ctx.route('https://original-project.supabase.co/**',net)
 page=ctx.new_page();page.on('pageerror',lambda e:print('BROWSER ERROR',str(e)[:200],flush=True));page.goto('http://127.0.0.1:8048/pruebas/');page.locator('#login-button:not([disabled])').wait_for()
 page.click('#device-check');page.get_by_text('browser.indexeddb',exact=True).wait_for()
 check('Actual Chromium secure-context WebCrypto and isolated IndexedDB checks succeed',page.locator('#results article.pass').count()==3)
 page.fill('[name=code]','COORD-01');page.fill('[name=password]','PRIVATE_PASSWORD_MARKER');page.click('#login-button');page.wait_for_function("document.querySelector('#message').textContent.startsWith('Controles terminados')")
 check('Readonly login workflow runs all expected mock API checks',page.locator('#results article.pass').count()==11)
 check('Password input cleared after test',page.input_value('[name=password]')=='')
 check('Session persistence is disabled',page.evaluate('__sdkCalls.find(c=>c.type==="client").opts.auth.persistSession') is False)
 for width in [320,390,768,1920]:
  page.set_viewport_size({'width':width,'height':844});check('Read-only page fits '+str(width),page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
 page.set_viewport_size({'width':390,'height':844});page.screenshot(path=str(OUT/'Pruebas_Movil.png'),full_page=True)
 with page.expect_download() as d:page.click('#export')
 f=d.value;path=OUT/'fixture-operator-result.json';f.save_as(path);text=path.read_text();j=json.loads(text)
 check('Evidence excludes password, key, token and candidate identity',not any(x in text for x in ['PRIVATE_PASSWORD_MARKER','PRIVATE_CANDIDATE_MARKER','PRIVATE_UUID_MARKER','PRIVATE_MARKER','sb_publishable']))
 check('Evidence never claims production activation or real hardware certified',j['production_activation_approved'] is False and j['automated_physical_certification'] is False and j['survey_write_test_completed_by_this_page'] is False)
 check('Untested physical observations remain untested',all(x['result']=='untested' for x in j['manual']))
 check('Probe invokes only read RPCs',set(page.evaluate('__sdkCalls.filter(c=>c.type==="rpc").map(c=>c.name)'))<=set(['v3_bootstrap','v3_preflight','v3_live_admin_state','v3_live_board']))
 check('Unsigned request cannot submit a survey',all('submit_response' not in r['url'] and 'v3_activate' not in r['url'] for r in requests))
 page.click('#logout');page.wait_for_function("document.querySelector('#message').textContent.startsWith('Sesión de prueba cerrada')")
 check('Logout uses local session scope only',page.evaluate('__sdkCalls.find(c=>c.type==="logout").scope')=='local')
 page.evaluate('window.__denyBootstrap=true');page.fill('[name=password]','PRIVATE_PASSWORD_MARKER');page.click('#login-button');page.wait_for_function("document.querySelector('#message').textContent.startsWith('La sesión respondió')")
 check('Denied App authorization leaves a clear persistent error, not a loading message',page.locator('#results article.fail').count()==1)
 page.goto('http://127.0.0.1:8048/pruebas/ensayo/v3/');page.get_by_role('heading',name='Ensayo sin configurar').wait_for()
 check('Unconfigured trial refuses fallback to original database',page.locator('#login-form').count()==0)
 page.goto('http://127.0.0.1:8048/pruebas/ensayo/');page.locator('#save:not([disabled])').wait_for()
 page.fill('[name=url]',config['supabaseUrl']);page.fill('[name=key]',config['publishableKey']);page.check('[name=confirmed]');page.click('#save');page.wait_for_function("document.querySelector('#message').textContent.startsWith('RECHAZADO')")
 check('Original production project is rejected as trial target',page.evaluate('localStorage.getItem("pulso-existing-test-project-1")') is None)
 page.fill('[name=url]','https://restored-project.supabase.co');page.click('#save');page.locator('#launch:not([hidden])').wait_for()
 check('Existing separate project can be configured without creating resources',json.loads(page.evaluate('localStorage.getItem("pulso-existing-test-project-1")'))['supabaseUrl']=='https://restored-project.supabase.co')
 for width in [320,390,768]:
  page.set_viewport_size({'width':width,'height':844});check('Trial setup fits '+str(width),page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
 page.goto('http://127.0.0.1:8048/pruebas/ensayo/v3/');page.locator('#login-form').wait_for()
 check('Unmodified field App uses only the existing trial target',page.evaluate('__sdkCalls.filter(c=>c.type==="client").every(c=>c.url==="https://restored-project.supabase.co")'))
 check('Field App is clearly marked as trial','ENSAYO · restored-project' in page.locator('body').inner_text())
 for route in ['live/','live/control.html']:
  page.goto('http://127.0.0.1:8048/pruebas/ensayo/'+route);page.wait_for_function('window.__sdkCalls?.length>0')
  check('Trial '+route+' never loads production as a fallback',page.evaluate('__sdkCalls.filter(c=>c.type==="client").every(c=>c.url==="https://restored-project.supabase.co")'))
 browser.close()
s.shutdown();(OUT/'browser-tests.json').write_text(json.dumps({'scope':'Actual Chromium browser and WebCrypto/IndexedDB. Auth/API responses use explicit fixtures; NOT physical phones or production authenticated acceptance. No cloud resource created.', 'passed':len(checks),'failed':0,'checks':checks},ensure_ascii=False,indent=2));print('PASS',len(checks))
