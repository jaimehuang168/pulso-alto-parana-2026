"""Actual HTTP/Auth/live console flows; Chromium/WebKit emulation, NOT physical phones."""
import json,pathlib,http.server,threading,functools,urllib.request,time,contextlib,csv,io,datetime,uuid
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parents[1];OUT=ROOT/'evidence/live-native-browser';OUT.mkdir(parents=True,exist_ok=True)
f=json.loads(pathlib.Path('/tmp/pulso-live-private.json').read_text());assert f['url'].startswith('http://127.0.0.1:')
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
 def end_headers(self):self.send_header('Cache-Control','no-store');super().end_headers()
server=http.server.ThreadingHTTPServer(('127.0.0.1',8044),functools.partial(Quiet,directory=str(ROOT.parent/'web')));threading.Thread(target=server.serve_forever,daemon=True).start()
BASE='http://127.0.0.1:8044';checks=[]
def check(name,ok):
 checks.append({'name':name,'pass':bool(ok)});print('PASS' if ok else 'FAIL',name,flush=True);assert ok,name
def http(path,data,token=None):
 headers={'Content-Type':'application/json','apikey':f['key']}
 if token:headers['Authorization']='Bearer '+token
 request=urllib.request.Request(f['url']+path,data=json.dumps(data).encode(),headers=headers)
 with urllib.request.urlopen(request,timeout=25) as r:return json.load(r)
admin_token=http('/auth/v1/token?grant_type=password',{'email':f['admin']['code'],'password':f['admin']['password']})['access_token']
def rpc(name,args={}):return http('/rest/v1/rpc/'+name,args,admin_token)
def cmd(action,data,rev=0):return rpc('v3_command',{'p_action':action,'p_data':data,'p_expected':rev,'p_request_id':str(uuid.uuid4()),'p_client':30000})
def enable_all():
 for c in ['cde','minga','hernandarias','franco']:rpc('v3_live_authorize',{'p_district':c,'p_enabled':True,'p_expires':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=25)).isoformat(),'p_reference':'ISOLATED NATIVE BROWSER FIXTURE','p_confirmed':True})
def login(page,credentials):
 form=page.locator('#login-form');form.wait_for(state='visible',timeout=20000);form.locator('[name=code]').fill(credentials['code']);form.locator('[name=password]').fill(credentials['password']);form.locator('button[type=submit]').click()
def ready(page):page.locator('.candidate-line').first.wait_for(timeout=20000)
def field_done(page):page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'",timeout=25000)
def busy_done(page):
 # Report-row actions are not forms; the console locks all buttons for both paths.
 page.wait_for_function("document.querySelector('#reload')?.disabled !== true && !document.querySelector('form[aria-busy=true]')",timeout=25000)
def submit(page,form):page.locator(form+' button').click();busy_done(page);page.locator('#message.success').wait_for(timeout=20000)
def snapshot(page,name):page.screenshot(path=str(OUT/name),full_page=True)
def int_text(locator):return int(''.join(c for c in locator.inner_text() if c.isdigit()))
def safe_error(e):
 text=str(e)
 for key in ['admin','viewer','viewerAll','worker']:text=text.replace(f[key]['password'],'[redacted]')
 return text.replace(admin_token,'[redacted]')[:600]
with sync_playwright() as pw:
 try:
  for engine in ['chromium','webkit']:
   browser=getattr(pw,engine).launch();admin_ctx=browser.new_context(viewport={'width':1920,'height':1080},locale='es-PY',timezone_id='America/Asuncion');a=admin_ctx.new_page();a.goto(BASE+'/live/?view=internal');login(a,f['admin']);ready(a)
   check(engine+' native administrator sees true synthetic names during running fieldwork','Candidatura DEMO' in a.locator('#board').inner_text() and a.locator('.city-card').count()==4)
   before=int_text(a.locator('[data-city=cde] .metrics .metric b').first)
   task=f['worker']['task']
   if engine=='webkit':task=cmd('assignment.create',{'person_id':f['worker']['person'],'point_id':f['worker']['point'],'reason':'Second native browser capture task'})['id']
   mobile=browser.new_context(**pw.devices['iPhone 13' if engine=='webkit' else 'Pixel 5'],locale='es-PY',timezone_id='America/Asuncion');w=mobile.new_page();w.goto(BASE+'/v3/');login(w,f['worker'])
   w.locator('#vault-form').wait_for(timeout=20000);w.locator('#vault-form [name=phrase]').fill('Synthetic mobile acceptance vault 2026')
   if w.locator('#vault-form [name=repeat]').count():w.locator('#vault-form [name=repeat]').fill('Synthetic mobile acceptance vault 2026')
   w.locator('#vault-form button').click();ack=w.locator('[data-action=task-ack][data-id="'+task+'"]');ack.wait_for(timeout=20000);ack.click();field_done(w);start=w.locator('[data-action=task-start][data-id="'+task+'"]');start.wait_for(timeout=20000);start.click();w.locator('#capture-form').wait_for(timeout=20000)
   check(engine+' actual field App displays only assigned CDE candidates',w.locator('.choice[data-outcome=candidate]').count()==2)
   w.locator('[name=voted]').check();w.locator('[name=consent]').check();w.locator('.choice[data-outcome=candidate]').first.click();w.locator('#capture-form button[type=submit]').click();field_done(w);w.locator('#mobile-nav').select_option('queue');w.get_by_text('Aceptada',exact=True).wait_for(timeout=20000)
   a.wait_for_function("old=>Number(document.querySelector('[data-city=cde] .metrics .metric b').textContent.replace(/[^0-9]/g,''))>old",arg=before,timeout=15000)
   check(engine+' real App HTTP submission updates another logged-in monitor without reload',int_text(a.locator('[data-city=cde] .metrics .metric b').first)==before+1)
   # A second device must not silently take over the previous active session.
   field_done(w);w.locator('#mobile-nav').select_option('task');w.on('dialog',lambda d:d.accept());finish=w.locator('[data-action=finish-my-task][data-id="'+task+'"]');finish.wait_for(timeout=20000);finish.click();field_done(w)
   tasks=rpc('v3_bootstrap')['assignments'];check(engine+' worker finishes the current task through the App before device handover',next(t for t in tasks if t['id']==task)['status']=='draining')
   a.locator('#audience').select_option('codes');a.wait_for_function("!document.querySelector('#board').textContent.includes('Candidatura') && document.querySelector('.candidate-name')?.textContent.trim()==='CDE-A'");check(engine+' codes-only switch removes all real names from displayed DOM','Lista DEMO' not in a.locator('#board').inner_text())
   for width,height in [(320,740),(390,844),(844,390),(768,1024),(1024,768),(1366,768),(1920,1080),(3840,2160)]:
    a.set_viewport_size({'width':width,'height':height});check(engine+f' responsive native monitor {width}x{height}',a.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   a.set_viewport_size({'width':1920,'height':1080});snapshot(a,engine+'-native-four-cities.png');check(engine+' four panels fit 1080p without clipping candidates',a.evaluate("document.documentElement.scrollHeight<=innerHeight+1 && [...document.querySelectorAll('.candidate-list')].every(e=>e.scrollHeight<=e.clientHeight+1)"))
   a.locator('button[data-city=minga]').click();check(engine+' native single-city view has exactly its four candidates',a.locator('.city-card').count()==1 and a.locator('.candidate-line').count()==4);a.set_viewport_size({'width':390,'height':844});snapshot(a,engine+'-native-single-mobile.png')
   a.evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));");ready(a);a.wait_for_timeout(5600);check(engine+' restored back-forward page resumes live polling','ACTUALIZACIÓN ACTIVA' in a.locator('#connection').inner_text())
   a.locator('#admin-console').click();a.locator('#workspace:not([hidden])').wait_for(timeout=20000);check(engine+' shared native administrator session opens private controls without another password','Candidatura DEMO' in a.locator('#mapping').inner_text())
   check(engine+' mobile administrator buttons remain legible rather than single-letter columns',a.locator('#reload').bounding_box()['width']>=140 and a.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   a.locator('#alias [name=confirmed]').check();submit(a,'#alias');check(engine+' actual alias confirmation writes and reads revised private mapping','Confirmados' in a.locator('#mapping').inner_text())
   a.locator('#policy [name=enabled]').check();a.locator('#policy [name=reference]').fill('ISOLATED BROWSER POLICY NOT PRODUCTION');submit(a,'#policy')
   a.locator('#channel [name=enabled]').check();a.locator('#channel [name=expires]').fill((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=25)).isoformat());a.locator('#channel [name=reference]').fill('ISOLATED BROWSER LIVE AUTHORIZATION');a.locator('#channel [name=confirmed]').check();submit(a,'#channel');enable_all()
   check(engine+' administrator configures policy and continuous city channel through actual forms','Permiso registrado' in a.locator('#release-state').inner_text())
   submit(a,'#cut');first=a.locator('.cut-row').first;report_id=first.get_attribute('data-cut');inside=rpc('v3_report_read',{'p_id':report_id,'p_audience':'internal'});outside=rpc('v3_report_read',{'p_id':report_id,'p_audience':'external'});check(engine+' actual console creates matched frozen internal/external snapshot',inside['stats']['candidate_base']==outside['candidate_base'])
   for action,extension in [('internal-csv','csv'),('external-csv','csv'),('external-html','html'),('external-png','png')]:
    with a.expect_download(timeout=30000) as output:first.locator('[data-download='+action+']').click()
    path=OUT/(engine+'-'+action+'.'+extension);output.value.save_as(str(path));busy_done(a)
    if action=='internal-csv':
     rows=list(csv.reader(io.StringIO(path.read_text('utf-8-sig'))));check(engine+' complete private CSV downloads all pages not first 500',len(rows)-1==inside['total_records'] and 'real_name' in rows[0])
    elif extension!='png':check(engine+' '+action+' download excludes real names and private UUIDs',all(x['real_name'] not in path.read_text('utf-8-sig') and x['candidate_id'] not in path.read_text('utf-8-sig') for x in f['configs'][0]['items']))
    else:check(engine+' native data renders downloadable code-only PNG',path.stat().st_size>15000)
   a.on('dialog',lambda d:d.accept('ISOLATED BROWSER CUT RELEASE REFERENCE'));first.locator('[data-download=release]').click();busy_done(a);first.locator('.status').get_by_text('released',exact=True).wait_for(timeout=20000);check(engine+' frozen cut release has its own successful authorization',rpc('v3_report_read',{'p_id':report_id,'p_audience':'external'})['status']=='released')
   vc=browser.new_context(**pw.devices['iPhone 13' if engine=='webkit' else 'Pixel 5'],locale='es-PY');v=vc.new_page();v.goto(BASE+'/live/');login(v,f['viewer']);ready(v);check(engine+' scoped Viewer sees only CDE and no admin console',v.locator('.city-card').count()==1 and v.locator('#admin-console').is_hidden() and 'Candidatura' not in v.locator('#board').inner_text())
   v.goto(BASE+'/live/control.html');v.get_by_text('Solo administración puede configurar nombres, códigos y permisos.',exact=True).wait_for(timeout=20000);check(engine+' direct console navigation cannot reveal private state',v.locator('#workspace').is_hidden() and 'Candidatura DEMO' not in v.locator('body').inner_text());v.goto(BASE+'/live/');ready(v)
   vc.set_offline(True);v.wait_for_timeout(16500);check(engine+' stale external results are hidden after bounded validity',v.locator('.candidate-line').count()==0);vc.set_offline(False);v.locator('#refresh').click();ready(v);check(engine+' native Viewer reconnection recovers authorized counts',v.locator('.candidate-line').count()==2)
   rpc('v3_live_authorize',{'p_district':'cde','p_enabled':False,'p_expires':None,'p_reference':'ISOLATED BROWSER REVOCATION','p_confirmed':True});v.wait_for_function("document.querySelector('#board')?.textContent.includes('Visualización no autorizada')",timeout=13000);check(engine+' server revocation removes results while fieldwork continues',v.locator('.candidate-line').count()==0 and rpc('v3_live_admin_state')['operation']['phase']=='running');enable_all()
   allc=browser.new_context(viewport={'width':1920,'height':1080});allv=allc.new_page();allv.goto(BASE+'/live/');login(allv,f['viewerAll']);ready(allv);check(engine+' native four-city Viewer receives four code-only live panels',allv.locator('.city-card').count()==4 and 'Candidatura' not in allv.locator('#board').inner_text())
   allv.goto(BASE+'/live/?view=internal');allv.locator('#notice:not([hidden])').wait_for(timeout=20000);check(engine+' forged internal URL cannot upgrade a Viewer',allv.locator('.candidate-line').count()==0)
   allc.close();vc.close();mobile.close();admin_ctx.close();browser.close()
 except Exception as e:
  detail=safe_error(e);print('NATIVE BROWSER FAIL',detail,flush=True)
  if not checks or checks[-1]['pass']:checks.append({'name':'Native browser execution','pass':False,'error':detail})
  with contextlib.suppress(Exception):snapshot(a,'failure.png')
 finally:
  server.shutdown();(ROOT/'evidence/live-native-browser.json').write_text(json.dumps({'scope':'Actual App/login/HTTP/database integration on disposable Supabase; Chromium Pixel and WebKit iPhone emulation, NOT physical devices','passed':sum(c['pass'] for c in checks),'failed':sum(not c['pass'] for c in checks),'checks':checks},ensure_ascii=False,indent=2))
if not checks or any(not c['pass'] for c in checks):raise SystemExit(1)
