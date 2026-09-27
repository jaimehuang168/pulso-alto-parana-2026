"""Authenticated V3.1 company forms in two actual engines against disposable HTTP backend."""
from pathlib import Path
import json,threading,http.server,functools
from playwright.sync_api import sync_playwright
R=Path(__file__).resolve().parents[2];F=json.loads(Path('/tmp/pulso-company-private.json').read_text());OUT=R/'v3/evidence/company-native-browser';OUT.mkdir(parents=True,exist_ok=True);checks=[]
assert F['url'].startswith('http://127.0.0.1:')
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8044),functools.partial(Quiet,directory=str(R/'web')));threading.Thread(target=srv.serve_forever,daemon=True).start()
def check(name,value):
 assert value,name
 checks.append({'name':name,'pass':True})
def idle(page):page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
def nav(page,name):
 idle(page)
 if page.locator('#mobile-nav').is_visible():page.locator('#mobile-nav').select_option(name)
 else:page.locator('[data-action=nav][data-id='+name+']:visible').click()
def login(page,cred):
 page.goto('http://127.0.0.1:8044/v3/');page.locator('#login-form [name=code]').fill(cred['code']);page.locator('#login-form [name=password]').fill(cred['password']);page.locator('#login-form button[type=submit]').click();page.get_by_role('heading',name='Centro de operación').wait_for(timeout=30000)
try:
 with sync_playwright() as p:
  for engine in ['chromium','webkit']:
   browser=getattr(p,engine).launch();ctx=browser.new_context(viewport={'width':390,'height':844});page=ctx.new_page();login(page,F['admin']);nav(page,'company');page.locator('#company-form [name=name]').fill('Empresa QA '+engine);page.locator('#company-form button[type=submit]').click();idle(page);page.reload();page.get_by_role('heading',name='Centro de operación').wait_for();nav(page,'company');check(engine+' real company form survives a full reload',page.locator('#company-form [name=name]').input_value()=='Empresa QA '+engine)
   nav(page,'access');page.locator('[data-action=access-new]').click();check(engine+' Super Admin sees admin creation after real login',page.locator('option[value=admin]').count()==1);page.locator('[data-action=close-modal]:visible').first.click();page.screenshot(path=str(OUT/(engine+'-super.png')),full_page=True)
   ctx.close();ctx=browser.new_context(viewport={'width':390,'height':844});page=ctx.new_page();login(page,F['company']);nav(page,'access');page.locator('[data-action=access-new]').click();check(engine+' company admin does not see admin creation',page.locator('option[value=admin]').count()==0);page.locator('[data-action=close-modal]:visible').first.click()
   row=page.locator('.listrow').filter(has_text='VIEW-COMPANY').first;row.locator('[data-action=actor-rename]').click();page.locator('.modal [name=display_name]').fill('Viewer corregido '+engine);page.locator('.modal [name=reason]').fill('Corrección de la misma identidad QA '+engine);page.locator('.modal button[type=submit]').click();page.locator('.modal').wait_for(state='detached');check(engine+' real account rename persists in visible list',page.get_by_text('VIEW-COMPANY · Viewer corregido '+engine,exact=False).count()==1)
   nav(page,'settings');check(engine+' company admin cannot activate technical cutover',page.locator('[data-action=activate]').count()==0);nav(page,'company');check(engine+' mobile company page has no horizontal overflow',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'));page.screenshot(path=str(OUT/(engine+'-company.png')),full_page=True)
   ctx.close();browser.close()
except Exception as e:
 checks.append({'name':'Native company browser flow','pass':False,'error':str(e)[:800]})
 try:page.screenshot(path=str(OUT/'failure.png'),full_page=True)
 except:pass
finally:
 srv.shutdown();d={'scope':'Actual Chromium/WebKit, real local Auth/HTTP; not physical devices or production','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks};(R/'v3/evidence/company-native-browser.json').write_text(json.dumps(d,indent=2));print(json.dumps(d,indent=2))
 if d['failed']:raise SystemExit(1)
