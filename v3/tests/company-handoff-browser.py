"""Company takes responsibility in actual HTTP UI. Nothing is written to production."""
from pathlib import Path
import json,threading,http.server,functools
from playwright.sync_api import sync_playwright,expect
R=Path(__file__).resolve().parents[2];f=json.loads(Path('/tmp/pulso-handoff-private.json').read_text());OUT=R/'v3/evidence/handoff-browser';OUT.mkdir(parents=True,exist_ok=True);results=[]
assert f['url'].startswith('http://127.0.0.1:')
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8044),functools.partial(Quiet,directory=str(R/'web')));threading.Thread(target=srv.serve_forever,daemon=True).start()
def check(name,v):
 assert v,name
 results.append({'name':name,'pass':True})
def idle(p):p.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
def nav(p,name):
 idle(p)
 if p.locator('#mobile-nav').is_visible():p.locator('#mobile-nav').select_option(name)
 else:p.locator(f'[data-action="nav"][data-id="{name}"]:visible').click()
 p.locator('[data-company-readiness]').wait_for() if name=='company' else None
 idle(p)
def login(p,c):
 p.goto('http://127.0.0.1:8044/v3/');p.locator('#login-form [name=code]').fill(c['code']);p.locator('#login-form [name=password]').fill(c['password']);p.locator('#login-form button[type=submit]').click();p.get_by_role('heading',name='Centro de operación').wait_for(timeout=30000)
def save(p):
 p.locator('#company-readiness-form button[type=submit]').click();idle(p)
 p.get_by_text('Avance guardado. No se ha activado V3 ni abierto encuestas.',exact=True).wait_for()
try:
 with sync_playwright() as play:
  for engine in ['chromium','webkit']:
   b=getattr(play,engine).launch();ctx=b.new_context(viewport={'width':390,'height':844});p=ctx.new_page();login(p,f['root']);nav(p,'company')
   check(engine+' Super Admin sees status but no three-input form',p.locator('#company-readiness-form').count()==0 and p.locator('[data-action=company-activate]').count()==0)
   p.screenshot(path=str(OUT/(engine+'-owner-status-only.png')),full_page=True)
   nav(p,'settings');check(engine+' settings do not ask owner to attest',p.locator('[data-action=activate]').count()==0 and 'corresponden al Admin de la empresa' in p.locator('body').inner_text())
   ctx.close();ctx=b.new_context(viewport={'width':390,'height':844});p=ctx.new_page();login(p,f['company']);nav(p,'company');p.locator('#company-readiness-form').wait_for()
   p.locator('#company-readiness-form [name=outbox]').uncheck();p.locator('[name=backup]').fill('');p.locator('[name=acceptance]').fill('');save(p)
   check(engine+' company can save all fields for later',p.locator('[data-action=company-activate]').is_disabled())
   p.reload();p.get_by_role('heading',name='Centro de operación').wait_for();nav(p,'company');check(engine+' empty saved draft remains empty after reload',p.locator('[name=backup]').input_value()=='' and not p.locator('[name=outbox]').is_checked())
   p.locator('[name=backup]').fill('Respaldo sintético '+engine);p.locator('[name=acceptance]').fill('Aceptación sintética '+engine);p.locator('[name=outbox]').check();save(p)
   check(engine+' saved complete draft enables company approval only',p.locator('[data-action=company-activate]').is_enabled())
   p.locator('[name=acceptance]').fill('Unsaved modification should not be used');p.locator('[data-action=company-activate]').click();p.get_by_text('Guarde los cambios',exact=True).wait_for();check(engine+' unsaved edits cannot silently activate', 'Preparación de V3' in p.locator('body').inner_text())
   p.locator('[data-action=readiness-refresh]').click();idle(p);expect(p.locator('[name=acceptance]')).to_have_value('Aceptación sintética '+engine)
   for width in [320,390,768,1366]:
    p.set_viewport_size({'width':width,'height':1000});check(engine+' responsive company checklist '+str(width),p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   p.set_viewport_size({'width':390,'height':844});p.screenshot(path=str(OUT/(engine+'-company-confirmations.png')),full_page=True)
   ctx.close();b.close()
except Exception as e:results.append({'name':'Browser execution','pass':False,'error':str(e)[:700]})
finally:
 srv.shutdown();d={'scope':'Real Chromium/WebKit with disposable local Auth/HTTP; not physical handsets','passed':sum(x['pass'] for x in results),'failed':sum(not x['pass'] for x in results),'checks':results};(R/'v3/evidence/handoff-browser.json').write_text(json.dumps(d,indent=2));print(json.dumps(d,indent=2))
 if d['failed']:raise SystemExit(1)
