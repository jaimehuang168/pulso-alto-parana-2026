"""Actual browser IndexedDB including a genuinely blocked delete request. Local only."""
import pathlib,json,threading,http.server,functools,os,contextlib
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parents[1];OUT=ROOT/'audit-evidence/storage-browser';OUT.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 extensions_map={**http.server.SimpleHTTPRequestHandler.extensions_map,'.mjs':'text/javascript'}
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8051),functools.partial(Quiet,directory=str(ROOT/'web')))
threading.Thread(target=srv.serve_forever,daemon=True).start();checks=[]
def check(name,ok):
 assert ok,name
 checks.append({'name':name,'pass':True});print('PASS',name,flush=True)
try:
 with sync_playwright() as p:
  for engine in os.environ.get('PULSO_TEST_ENGINES','chromium,webkit').split(','):
   browser=getattr(p,engine).launch();ctx=browser.new_context(viewport={'width':428,'height':843});page=ctx.new_page()
   ctx.route('**/*.supabase.co/**',lambda r:r.abort())
   page.goto('http://127.0.0.1:8051/pruebas/');page.evaluate("async()=>{window.diag=await import('./storage-diagnostic.mjs');}")
   data=page.evaluate('async()=>await diag.diagnoseStorage()')
   check(engine+' actual native IndexedDB commits write and read and deletes only temporary DB',data['readwrite_status']=='pass' and data['cleanup_status']=='pass' and all(s['status']=='pass' for s in data['stages']))
   page.evaluate("async()=>{await new Promise((ok,no)=>{const r=indexedDB.open('QA_EXISTING_OUTBOX_SENTINEL',1);r.onupgradeneeded=()=>r.result.createObjectStore('saved');r.onsuccess=()=>{const db=r.result,t=db.transaction('saved','readwrite');t.objectStore('saved').put('DO_NOT_TOUCH','sentinel');t.oncomplete=()=>{db.close();ok();};t.onerror=no;};r.onerror=no;});}")
   page.evaluate('async()=>await diag.diagnoseStorage()')
   preserved=page.evaluate("async()=>await new Promise((ok,no)=>{const r=indexedDB.open('QA_EXISTING_OUTBOX_SENTINEL');r.onsuccess=()=>{const db=r.result,q=db.transaction('saved').objectStore('saved').get('sentinel');q.onsuccess=()=>{const v=q.result;db.close();ok(v);};q.onerror=no;};r.onerror=no;})")
   check(engine+' unrelated existing storage is never cleared or opened by diagnostic',preserved=='DO_NOT_TOUCH')
   failure=page.evaluate("async()=>{window.cleanupName=null;const factory={open:(...args)=>indexedDB.open(...args),deleteDatabase:name=>{cleanupName=name;throw new DOMException('private browser detail','SecurityError');}};return await diag.diagnoseStorage({factory});}")
   check(engine+' cleanup SecurityError does not mask successful native read/write',failure['readwrite_status']=='pass' and failure['cleanup_status']=='fail' and failure['stages'][-1]['error_name']=='SecurityError')
   page.evaluate("async()=>await new Promise((ok,no)=>{const r=indexedDB.deleteDatabase(cleanupName);r.onsuccess=ok;r.onerror=no;})")
   blocked=page.evaluate("async()=>{window.held=null;window.pendingDelete=null;const factory={open:(...args)=>indexedDB.open(...args),deleteDatabase:name=>{const keep=indexedDB.open(name);keep.onsuccess=()=>held=keep.result;pendingDelete=indexedDB.deleteDatabase(name);return pendingDelete;}};return await diag.diagnoseStorage({factory,timeoutMs:3000});}")
   check(engine+' genuine blocked deletion is a distinct cleanup result',blocked['readwrite_status']=='pass' and blocked['cleanup_status']=='blocked' and blocked['stages'][-1]['error_name']=='BlockedError')
   page.evaluate("async()=>await new Promise((ok,no)=>{pendingDelete.onsuccess=ok;pendingDelete.onerror=no;held.close();})")
   combined=page.evaluate("async()=>{const factory={open:()=>{throw new DOMException('DO_NOT_EXPORT','QuotaExceededError');},deleteDatabase:()=>{throw new DOMException('DO_NOT_EXPORT','SecurityError');}};return await diag.diagnoseStorage({factory});}")
   check(engine+' primary failure and cleanup failure are both preserved',combined['failure_stage']=='open' and combined['error_name']=='QuotaExceededError' and combined['stages'][-1]['error_name']=='SecurityError')
   check(engine+' diagnostic JSON never exposes arbitrary native messages','DO_NOT_EXPORT' not in json.dumps(combined) and 'private browser detail' not in json.dumps(failure))
   page.click('#storage-check');page.wait_for_function("document.querySelector('#message').textContent.startsWith('Almacenamiento y limpieza conformes')")
   with page.expect_download() as d:page.click('#export')
   dest=OUT/(engine+'-storage-only-result.json');d.value.save_as(dest);data=json.loads(dest.read_text())
   check(engine+' storage-only button exports schema 2 with no login and no survey certification',data['schema']=='pulso-pruebas-2' and data['storage_diagnostic']['readwrite_status']=='pass' and not data['survey_write_test_completed_by_this_page'])
   for w in [320,390,428,768]:
    page.set_viewport_size({'width':w,'height':843});check(engine+' storage stage details readable at '+str(w),page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   page.set_viewport_size({'width':428,'height':843});page.locator('#storage-details').screenshot(path=str(OUT/(engine+'-storage-stages.png')))
   ctx.close();browser.close()
except Exception as e:
 checks.append({'name':'Storage browser execution','pass':False,'error':str(e)[:700]});raise
finally:
 srv.shutdown();(OUT/'results.json').write_text(json.dumps({'scope':'Chromium/WebKit native browser IndexedDB; deliberate DOMException injection for selected faults; no production or real-phone test','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks},ensure_ascii=False,indent=2))
