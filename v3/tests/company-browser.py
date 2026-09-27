"""Company UI and documentation screens; local synthetic DB only (not hosted/physical)."""
from pathlib import Path
import json,threading,http.server,functools,os
from playwright.sync_api import sync_playwright
R=Path(__file__).resolve().parents[1];OUT=R/'evidence/company-browser';OUT.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8058),functools.partial(Quiet,directory=str(R/'preview')));threading.Thread(target=srv.serve_forever,daemon=True).start()
checks=[]
def check(name,ok):
 assert ok,name
 checks.append({'name':name,'pass':True})
def action(page,name,id=None):
 page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
 page.locator('[data-action="'+name+'"]'+('[data-id="'+id+'"]' if id else '')+':visible').first.click()
def nav(page,name):
 page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
 if page.locator('#mobile-nav').is_visible():page.locator('#mobile-nav').select_option(name)
 else:action(page,'nav',name)
 page.wait_for_timeout(200)
try:
 with sync_playwright() as p:
  engine=os.environ.get('PULSO_BROWSER','chromium');args={'executable_path':'/usr/bin/chromium'} if engine=='chromium' and Path('/usr/bin/chromium').exists() else {}
  browser=getattr(p,engine).launch(**args);ctx=browser.new_context(viewport={'width':1440,'height':1050});ctx.route('**/*.supabase.co/**',lambda r:r.abort());page=ctx.new_page()
  page.goto('http://127.0.0.1:8058/');page.get_by_role('button',name='Administrador',exact=True).wait_for(timeout=90000);page.get_by_role('button',name='Administrador',exact=True).click();page.get_by_role('heading',name='Centro de operación').wait_for(timeout=30000)
  check('Super label displayed from server bootstrap',page.get_by_text('Super Admin · propietario',exact=False).count()>0)
  nav(page,'company');page.locator('#company-form [name=name]').fill('Empresa DEMO — configurar con sus datos');page.locator('#company-form [name=contact_name]').fill('Responsable DEMO');page.locator('#company-form [name=support_email]').fill('soporte@example.invalid');page.locator('#company-form button[type=submit]').click();page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'");page.wait_for_timeout(300)
  check('Actual SQL company form save and readback',page.locator('#company-form [name=name]').input_value().startswith('Empresa DEMO'))
  page.screenshot(path=str(OUT/'01_empresa.png'),full_page=True)
  for width in [320,390,768,1440]:
   page.set_viewport_size({'width':width,'height':1000});check('Company layout '+str(width)+'px',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  page.set_viewport_size({'width':1440,'height':1050});nav(page,'access');page.screenshot(path=str(OUT/'02_superadmin_accesos.png'),full_page=True)
  rootrows=page.locator('.listrow').filter(has_text='COORD-01');check('Owner row has no disable/reset action',rootrows.locator('[data-action="actor-disable"],[data-action="reset-worker"]').count()==0)
  adminrow=page.locator('.listrow').filter(has_text='ADMIN-DEMO');check('Super Admin can disable company admin in UI',adminrow.locator('[data-action="actor-disable"]').count()==1)
  action(page,'access-new');check('Super Admin can select new admin role',page.locator('#access-form option[value=admin]').count()==1);page.screenshot(path=str(OUT/'03_crear_admin.png'),full_page=True);action(page,'close-modal')
  adminrow.locator('[data-action="actor-rename"]').click();page.locator('.modal [name=display_name]').fill('Administración DEMO corregida');page.locator('.modal [name=reason]').fill('Corrección de nombre de la misma persona DEMO');page.locator('.modal button[type=submit]').click();page.locator('.modal').wait_for(state='detached');check('Rename admin persists with same code',page.get_by_text('ADMIN-DEMO · Administración DEMO corregida',exact=False).count()==1)
  for route,num in [('catalog','04'),('points','05'),('people','06'),('tasks','07'),('settings','08'),('imports','09')]:
   nav(page,route);page.screenshot(path=str(OUT/(num+'_'+route+'.png')),full_page=True);check('Existing admin route '+route,page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  nav(page,'people');action(page,'person-rename');page.locator('.modal [name=display_name]').fill('Encuestador DEMO corregido');page.locator('.modal [name=reason]').fill('Corrección de la misma persona, no relevo');page.locator('.modal button[type=submit]').click();page.locator('.modal').wait_for(state='detached');check('Personnel correction succeeds through SQL',page.get_by_text('Encuestador DEMO corregido',exact=False).count()>0)
  action(page,'logout');page.get_by_role('button',name='Admin de empresa',exact=True).click();page.get_by_role('heading',name='Centro de operación').wait_for();nav(page,'access');action(page,'access-new');check('Company admin cannot select admin role',page.locator('#access-form option[value=admin]').count()==0);action(page,'close-modal');check('Company admin cannot disable owner',page.locator('.listrow').filter(has_text='COORD-01').locator('[data-action="actor-disable"],[data-action="reset-worker"]').count()==0)
  page.screenshot(path=str(OUT/'10_admin_empresa.png'),full_page=True);nav(page,'settings');check('Company admin has no activation button',page.locator('[data-action="activate"]').count()==0)
  action(page,'logout');page.get_by_role('button',name='Encuestador CDE',exact=True).click();page.locator('#vault-form').wait_for();page.locator('[name=phrase]').fill('Synthetic testing local protection 2026');page.locator('[name=repeat]').fill('Synthetic testing local protection 2026');page.locator('#vault-form button[type=submit]').click();page.locator('#vault-form').wait_for(state='detached');action(page,'task-start');page.get_by_role('heading',name='Nueva encuesta').wait_for();page.set_viewport_size({'width':390,'height':844});page.screenshot(path=str(OUT/'11_encuesta_movil.png'),full_page=True)
  check('Interviewer cannot navigate to company or account admin',page.locator('#mobile-nav option[value=company],#mobile-nav option[value=access]').count()==0)
  page.locator('[name=voted]').check();page.locator('[name=consent]').check();page.locator('.choice[data-outcome=candidate]').first.click();page.locator('#capture-form button[type=submit]').click();nav(page,'queue');page.get_by_text('Aceptada',exact=True).wait_for(timeout=20000);check('Existing capture still gets a real isolated SQL receipt',page.get_by_text('Aceptada',exact=True).count()==1);page.screenshot(path=str(OUT/'12_recibo_movil.png'),full_page=True)
  browser.close()
except Exception as e:
 checks.append({'name':'Company browser flow','pass':False,'error':str(e)[:800]})
 try:page.screenshot(path=str(OUT/'FAILURE.png'),full_page=True)
 except:pass
 print(str(e))
finally:
 srv.shutdown();d={'scope':'Actual browser and local SQL simulation; no hosted Auth, no physical device','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks};(OUT/'results.json').write_text(json.dumps(d,ensure_ascii=False,indent=2));print(json.dumps(d,ensure_ascii=False,indent=2))
 if d['failed']:raise SystemExit(1)
