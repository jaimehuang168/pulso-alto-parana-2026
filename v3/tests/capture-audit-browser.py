"""Actual App controls + browser SQL and encrypted outbox. Synthetic Auth, localhost only."""
import pathlib,json,threading,http.server,functools,os,contextlib
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parents[2];OUT=ROOT/'audit-evidence/capture-browser';OUT.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 extensions_map={**http.server.SimpleHTTPRequestHandler.extensions_map,'.mjs':'text/javascript'}
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8052),functools.partial(Quiet,directory=str(ROOT/'v3/preview')));threading.Thread(target=srv.serve_forever,daemon=True).start();checks=[]
def check(name,ok):
 assert ok,name
 checks.append({'name':name,'pass':True});print('PASS',name,flush=True)
def idle(page):page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'",timeout=20000)
def nav(page,name):
 idle(page);page.locator('#mobile-nav').select_option(name);page.wait_for_timeout(120)
def count(page):return page.evaluate('async()=>(await __captureAudit.api.rpc("v3_records")).length')
def capture(page,outcome,index=0,consent=True):
 nav(page,'capture');page.get_by_role('heading',name='Nueva encuesta').wait_for();page.locator('[name=voted]').check()
 if consent:page.locator('[name=consent]').check()
 target=page.locator('.choice[data-outcome='+outcome+']');target.nth(index).click();idle(page)
 page.locator('#capture-form button[type=submit]').click();idle(page)
try:
 with sync_playwright() as p:
  for engine in os.environ.get('PULSO_TEST_ENGINES','chromium,webkit').split(','):
   browser=getattr(p,engine).launch();ctx=browser.new_context(viewport={'width':428,'height':843},accept_downloads=True);page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
   ctx.route('**/*.supabase.co/**',lambda r:r.abort())
   page.goto('http://127.0.0.1:8052/');page.get_by_role('button',name='Encuestador CDE',exact=True).wait_for(timeout=90000);page.get_by_role('button',name='Encuestador CDE',exact=True).click()
   page.locator('#vault-form').wait_for();page.locator('[name=phrase]').fill('QA synthetic storage phrase 2026');page.locator('[name=repeat]').fill('QA synthetic storage phrase 2026');page.locator('#vault-form button').click();idle(page)
   page.locator('[data-action=task-start]').click();idle(page);page.locator('#capture-form').wait_for()
   check(engine+' only CDE task names and two candidate buttons are shown',page.locator('.choice[data-outcome=candidate]').count()==2 and 'Ciudad del Este' in page.locator('.taskbar').inner_text())
   page.locator('.choice[data-outcome=candidate]').nth(0).click();idle(page);page.locator('.choice[data-outcome=candidate]').nth(1).click();idle(page)
   check(engine+' switching selection leaves exactly one selected candidate and correct summary',page.locator('.choice[aria-pressed=true]').count()==1 and 'DEMO B' in page.locator('#selection-summary').inner_text())
   page.locator('#capture-form button[type=submit]').click();idle(page)
   check(engine+' not-already-voted blocks all storage/submit calls',len(page.evaluate('__captureAudit.submissions'))==0 and count(page)==0)
   page.locator('[name=voted]').check();page.locator('#capture-form button[type=submit]').click();idle(page)
   check(engine+' missing consent cannot create a candidate response',len(page.evaluate('__captureAudit.submissions'))==0 and count(page)==0)
   page.locator('[name=consent]').check()
   page.locator('#capture-form').evaluate("f=>{f.requestSubmit();f.requestSubmit();}");idle(page)
   check(engine+' double submit during save creates exactly one UUID and one receipt',count(page)==1 and len(page.evaluate('__captureAudit.submissions'))==1)
   check(engine+' next contact resets choice and participation controls',page.locator('.choice[aria-pressed=true]').count()==0 and not page.locator('[name=voted]').is_checked() and not page.locator('[name=consent]').is_checked())
   capture(page,'candidate');capture(page,'candidate');capture(page,'blank');capture(page,'refused',consent=False)
   rows=page.evaluate('async()=>await __captureAudit.api.rpc("v3_records")')
   check(engine+' A2 B1 blank1 refusal1 survives exact App button selection',len(rows)==5 and sum(x['outcome']=='candidate' and x['candidate_name']=='Candidatura DEMO A' for x in rows)==2 and sum(x['outcome']=='candidate' and x['candidate_name']=='Candidatura DEMO B' for x in rows)==1 and sum(x['outcome']=='blank' for x in rows)==1 and sum(x['outcome']=='refused' for x in rows)==1)
   refusal=next(x for x in rows if x['outcome']=='refused');check(engine+' refusal has neither candidate nor consent',refusal['candidate_id'] is None and refusal['consent'] is False)
   nav(page,'capture');page.locator('.choice[data-outcome=refused]').click();idle(page);check(engine+' refusal disables consent control',page.locator('[name=consent]').is_disabled())
   page.locator('.choice[data-outcome=candidate]').first.click();idle(page);check(engine+' candidate selection re-enables consent without fabricating it',not page.locator('[name=consent]').is_disabled() and not page.locator('[name=consent]').is_checked())
   for w in [320,390,428,768]:
    page.set_viewport_size({'width':w,'height':843});check(engine+' capture form has no horizontal overflow at '+str(w),page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   page.set_viewport_size({'width':428,'height':843});page.screenshot(path=str(OUT/(engine+'-capture.png')),full_page=True)
   ctx.set_offline(True);before=len(page.evaluate('__captureAudit.submissions'));capture(page,'candidate');nav(page,'queue')
   check(engine+' offline capture is held locally and not counted on server',len(page.evaluate('__captureAudit.submissions'))==before and count(page)==5)
   check(engine+' offline item is visibly pending',page.get_by_text('Pendiente de confirmación',exact=True).count()==1)
   ctx.set_offline(False);page.wait_for_function('window.__captureAudit.submissions.length===6',timeout=20000);idle(page);page.wait_for_timeout(500)
   check(engine+' reconnect adds the offline contact once',count(page)==6)
   nav(page,'queue');page.locator('[data-action=sync]').click();idle(page);check(engine+' manual sync does not double-count confirmed receipts',count(page)==6)
   page.evaluate('__captureAudit.dropNextReceipt=true');capture(page,'candidate',index=1);check(engine+' lost HTTP-style response still leaves one server record',count(page)==7)
   nav(page,'queue');page.locator('[data-action=sync]').click();idle(page);check(engine+' readback recovers lost receipt without adding another vote',count(page)==7)
   page.once('dialog',lambda d:d.accept());page.locator('[data-action=void]').first.click();idle(page);rows=page.evaluate('async()=>await __captureAudit.api.rpc("v3_records")')
   check(engine+' void retains original row while marking it excluded',len(rows)==7 and sum(r['disposition']=='excluded' for r in rows)==1)
   nav(page,'task');page.once('dialog',lambda d:d.accept());page.locator('[data-action=finish-my-task]').click();idle(page);check(engine+' finish task disables new work and retains draining queue',page.get_by_text('Solo envío pendiente',exact=True).count()>0 and page.locator('[data-action=task-start]').count()==0)
   page.locator('[data-action=logout]:visible').first.click();idle(page);page.get_by_role('button',name='Viewer CDE',exact=True).click();idle(page)
   check(engine+' Viewer has no capture, administration or task mutation controls',page.get_by_role('heading',name='Acceso a resultados pendiente',exact=True).is_visible() and not page.locator('[data-action=task-start],[data-action=person-new],[data-action=choice]').count())
   check(engine+' no unhandled browser exception',not errors);ctx.close();browser.close()
except Exception as e:
 checks.append({'name':'Capture browser execution','pass':False,'error':str(e)[:700]})
 with contextlib.suppress(Exception):page.screenshot(path=str(OUT/'failure.png'),full_page=True)
 raise
finally:
 srv.shutdown();(OUT/'results.json').write_text(json.dumps({'scope':'Actual App events, browser IndexedDB and PGlite SQL. Synthetic Auth and injected response latency/loss; no hosted or physical phone test.','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks},ensure_ascii=False,indent=2))
