"""Authenticated company forms in Chromium/WebKit and disposable Supabase."""
from pathlib import Path
import json,threading,http.server,functools
from playwright.sync_api import sync_playwright
R=Path(__file__).resolve().parents[2];F=json.loads(Path('/tmp/pulso-company-private.json').read_text());OUT=R/'v3/evidence/company-native-browser';OUT.mkdir(parents=True,exist_ok=True);checks=[];failed_http=[]
assert F['url'].startswith('http://127.0.0.1:')
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8044),functools.partial(Quiet,directory=str(R/'web')));threading.Thread(target=srv.serve_forever,daemon=True).start()
def check(name,value):
 assert value,name
 checks.append({'name':name,'pass':True})
def idle(page):page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
def action(page,name):
 idle(page);page.locator('[data-action="'+name+'"]:visible').first.click();idle(page)
def nav(page,name):
 idle(page)
 groups={'tasks':'people','access':'people','catalog':'company','imports':'company','exports':'company','settings':'company','review':'registry','paper':'registry','task':'capture'}
 target=page.locator('[data-action=nav][data-id="'+name+'"]:visible')
 if not target.count():
  page.locator('[data-action=nav][data-id="'+groups.get(name,name)+'"]:visible').first.click();idle(page)
 page.locator('[data-action=nav][data-id="'+name+'"]:visible').first.click();idle(page)
def observe(response):
 if '/rest/v1/rpc/' in response.url and response.status>=400:
  try:
   value=response.json();failed_http.append({'rpc':response.url.split('/rpc/')[-1],'status':response.status,'code':value.get('code'),'message':str(value.get('message',''))[:160]})
  except:failed_http.append({'status':response.status})
def login(page,cred):
 page.on('response',observe);page.goto('http://127.0.0.1:8044/v3/');page.locator('#login-form [name=code]').fill(cred['code']);page.locator('#login-form [name=password]').fill(cred['password']);page.locator('#login-form button[type=submit]').click();page.get_by_role('heading',name='Resultados').wait_for(timeout=30000);idle(page)
try:
 with sync_playwright() as p:
  for engine in ['chromium','webkit']:
   browser=getattr(p,engine).launch();ctx=browser.new_context(viewport={'width':390,'height':844});page=ctx.new_page();login(page,F['admin']);nav(page,'company');page.locator('#company-form [name=name]').fill('Empresa QA '+engine);page.locator('#company-form button[type=submit]').click();idle(page);page.reload();page.get_by_role('heading',name='Resultados').wait_for();nav(page,'company');check(engine+' real company form survives a full reload',page.locator('#company-form [name=name]').input_value()=='Empresa QA '+engine)
   nav(page,'access');action(page,'access-new');check(engine+' privileged account sees admin creation after real login',page.locator('option[value=admin]').count()==1);action(page,'close-modal');page.screenshot(path=str(OUT/(engine+'-super.png')),full_page=True)
   ctx.close();ctx=browser.new_context(viewport={'width':390,'height':844});page=ctx.new_page();login(page,F['company']);nav(page,'access');action(page,'access-new');check(engine+' company admin does not see admin creation',page.locator('option[value=admin]').count()==0);action(page,'close-modal')
   row=page.locator('.listrow').filter(has_text='VIEW-COMPANY').first;row.locator('[data-action=actor-rename]').click();idle(page);page.locator('.modal [name=display_name]').fill('Viewer corregido '+engine);page.locator('.modal [name=reason]').fill('Corrección de la misma identidad QA '+engine)
   assert page.locator('.modal form').evaluate('(f)=>f.checkValidity()'),'Rename form validity'
   with page.expect_response(lambda r:'/rest/v1/rpc/v3_company_command' in r.url,timeout=20000) as sent:page.locator('.modal button[type=submit]').click()
   assert sent.value.status==200,'Rename HTTP failed '+str(failed_http)
   page.locator('.modal').wait_for(state='detached');idle(page)
   renamed=page.get_by_text('VIEW-COMPANY · Viewer corregido '+engine,exact=False);renamed.wait_for(timeout=20000);check(engine+' real account rename persists in visible list',renamed.count()==1)
   nav(page,'settings');check(engine+' company admin cannot activate technical cutover',page.locator('[data-action=activate]').count()==0);nav(page,'company');check(engine+' mobile company page has no horizontal overflow',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'));page.screenshot(path=str(OUT/(engine+'-company.png')),full_page=True)
   ctx.close();browser.close()
except Exception as e:
 detail={'name':'Native company browser flow','pass':False,'error':str(e)[:800],'rpc_errors':failed_http}
 try:
  detail['form_state']=page.locator('.modal form').evaluate('(f)=>({id:f.id,revision:f.dataset.revision,valid:f.checkValidity(),errors:[...f.querySelectorAll(":invalid")].map(x=>({name:x.name,error:x.validationMessage})),feedback:f.querySelector(".form-error")?.textContent,busy:document.querySelector("#app")?.getAttribute("aria-busy")})')
  page.screenshot(path=str(OUT/'FAILURE.png'),full_page=True)
 except:pass
 checks.append(detail)
finally:
 srv.shutdown();d={'scope':'Actual Chromium/WebKit, real local Auth/HTTP; not physical devices or production','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks};(R/'v3/evidence/company-native-browser.json').write_text(json.dumps(d,indent=2));print(json.dumps(d,indent=2))
 if d['failed']:raise SystemExit(1)
