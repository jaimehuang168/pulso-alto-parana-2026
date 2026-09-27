"""Real 3.1.3 UI in the isolated SQL simulator. Never connects to production.
Unsupported account creation is shown as a form, not submitted or claimed tested.
"""
from pathlib import Path
import argparse,functools,http.server,json,re,threading
from playwright.sync_api import sync_playwright

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--demo',type=Path,required=True);ap.add_argument('--login',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
 class Quiet(http.server.SimpleHTTPRequestHandler):
  def log_message(self,*args):pass
  def end_headers(self):self.send_header('Cache-Control','no-store');super().end_headers()
 servers=[]
 for folder,port in [(a.demo,8063),(a.login,8064)]:
  s=http.server.ThreadingHTTPServer(('127.0.0.1',port),functools.partial(Quiet,directory=str(folder)));threading.Thread(target=s.serve_forever,daemon=True).start();servers.append(s)
 shots={};checks=[];page=None
 def idle():page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'");page.wait_for_timeout(250)
 def act(name,id=None):
  idle();page.locator('[data-action="'+name+'"]'+('[data-id="'+id+'"]' if id else '')+':visible').first.click();idle()
 def nav(name):
  groups={'tasks':'people','access':'people','catalog':'company','imports':'company','exports':'company','settings':'company','review':'registry','paper':'registry','task':'capture'}
  if not page.locator('[data-action=nav][data-id="'+name+'"]:visible').count():act('nav',groups.get(name,name))
  act('nav',name)
 def shot(name,focus=None):
  idle();text=page.locator('body').inner_text();assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',text)
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth+1')
  target=page.locator(focus).first if focus else page
  target.screenshot(path=str(a.out/(name+'.png')))
  shots[name]={'file':name+'.png','viewport':page.viewport_size,'isolated':True,'text':text[:25000]};print('CAPTURE',name,flush=True)
 def fill(selector,value):page.locator(selector).fill(value)
 def close():act('close-modal')
 def save():page.locator('.modal button[type=submit]').click();page.locator('.modal').wait_for(state='detached',timeout=20000);idle()
 def answer(kind,index=0):
  nav('capture');page.locator('[name=voted]').check()
  if kind!='refused':page.locator('[name=consent]').check()
  page.locator('.choice[data-outcome="'+kind+'"]').nth(index).click();page.locator('#capture-form button[type=submit]').click();idle();nav('queue');page.get_by_text('Aceptada',exact=True).first.wait_for(timeout=20000)
 try:
  with sync_playwright() as p:
   b=p.chromium.launch();ctx=b.new_context(viewport={'width':1320,'height':850},device_scale_factor=1)
   ctx.route('**/*',lambda r:r.continue_() if r.request.url.startswith(('http://127.0.0.1:8063/','http://127.0.0.1:8064/','data:','blob:')) else r.abort())
   page=ctx.new_page();page.on('dialog',lambda d:d.accept());page.goto('http://127.0.0.1:8064/');page.locator('#login-form').wait_for();fill('#login-form [name=code]','ADMIN-EMPRESA');shot('a_login')
   page.goto('http://127.0.0.1:8063/');page.get_by_role('button',name='Encuestador CDE',exact=True).wait_for(timeout=120000);page.get_by_role('button',name='Encuestador CDE',exact=True).click();page.locator('#vault-form').wait_for();fill('[name=phrase]','Practica local del video 2026');fill('[name=repeat]','Practica local del video 2026');page.locator('#vault-form button[type=submit]').click();page.locator('#vault-form').wait_for(state='detached');act('task-start')
   for kind,index in [('candidate',0),('candidate',0),('candidate',1),('blank',0),('refused',0)]:answer(kind,index)
   act('logout');page.get_by_role('button',name='Admin de empresa',exact=True).click();page.get_by_role('heading',name='Resultados',exact=True).wait_for();shot('a_results');checks.append({'name':'Five primary work areas','pass':page.locator('.sidebar nav [data-group]').count()==5})
   nav('company');fill('#company-form [name=name]','Empresa de encuestas DEMO');fill('#company-form [name=contact_name]','Coordinación DEMO');fill('#company-form [name=support_email]','soporte@example.invalid');shot('a_company_edit');page.locator('#company-form button[type=submit]').click();idle();shot('a_company_saved')
   nav('catalog');shot('a_candidates');act('questionnaire-new');fill('.modal [name=methodology]','Ejemplo de formación: participación voluntaria y selección según el intervalo establecido.');fill('.modal [name=reference]','Referencia sintética del tutorial');shot('a_candidate_form','.modal');close()
   nav('points');act('station-new');fill('.modal [name=code]','TUTORIAL-CDE');fill('.modal [name=name]','Local de formación DEMO');fill('.modal [name=address]','Dirección de formación; no es un local oficial');shot('a_station_form','.modal');save();shot('a_sites')
   act('point-new');fill('.modal [name=code]','TUTORIAL-PT-01');fill('.modal [name=label]','Entrada de formación DEMO');shot('a_point_form','.modal');close()
   nav('access');shot('a_accounts');act('access-new');shot('a_access_form','.modal');checks.append({'name':'Company admin has no admin-creation option','pass':page.locator('#access-form option[value=admin]').count()==0});close()
   if page.locator('[data-action=grant-new]').count():act('grant-new');shot('a_scope','.modal');close()
   nav('people');shot('a_team');act('person-new');fill('.modal [name=display_name]','Persona de formación DEMO');shot('a_person_form','.modal');save();shot('a_person_saved')
   nav('tasks');shot('a_tasks');act('task-new');fill('.modal [name=reason]','Asignación de ejemplo: verificar persona y punto');shot('a_task_form','.modal');close()
   nav('settings');shot('a_operation');nav('imports');shot('a_import');nav('overview');act('filter-city','cde');shot('a_city')
   nav('registry');shot('a_registry');checks.append({'name':'Five contacts read back in registry','pass':page.locator('[data-action=record-detail]').count()==5})
   act('record-detail');shot('a_record_detail','.modal');close();nav('exports');shot('a_exports');nav('overview');act('filter-reset');shot('a_four_cities');nav('guide');shot('a_help')
   act('logout');page.set_viewport_size({'width':430,'height':844});page.get_by_role('button',name='Encuestador CDE',exact=True).click();page.locator('#vault-form').wait_for();shot('u_protection');fill('[name=phrase]','Practica local del video 2026');page.locator('#vault-form button[type=submit]').click();page.locator('#vault-form').wait_for(state='detached');nav('task');shot('u_task')
   if page.locator('[data-action=training]').count():act('training');shot('u_training','.modal');close()
   nav('capture');shot('u_capture');checks.append({'name':'Only own two candidate options','pass':page.locator('.choice[data-outcome=candidate]').count()==2})
   page.locator('[name=voted]').check();page.locator('[name=consent]').check();page.locator('.choice[data-outcome=candidate]').first.click();shot('u_choice');page.locator('.capture-actions').scroll_into_view_if_needed();shot('u_save');page.locator('#capture-form button[type=submit]').click();idle();nav('queue');page.get_by_text('Aceptada',exact=True).first.wait_for();shot('u_receipt')
   nav('capture');page.locator('[name=voted]').check();page.locator('.choice[data-outcome=refused]').click();page.locator('.choice[data-outcome=refused]').scroll_into_view_if_needed();shot('u_refused');checks.append({'name':'Refusal clears consent','pass':page.locator('[name=consent]').is_disabled() and not page.locator('[name=consent]').is_checked()});page.locator('#capture-form button[type=submit]').click();idle()
   ctx.set_offline(True);nav('capture');page.locator('[name=voted]').check();page.locator('[name=consent]').check();page.locator('.choice[data-outcome=candidate]').first.click();page.locator('#capture-form button[type=submit]').click();idle();nav('queue');shot('u_offline');checks.append({'name':'Encrypted pending while offline','pass':'Pendiente de confirmación' in page.locator('body').inner_text()});ctx.set_offline(False);idle();act('sync');page.wait_for_timeout(1200);shot('u_synced')
   nav('records');shot('u_records');nav('task');shot('u_finish');nav('guide');shot('u_help');checks.append({'name':'No company/account controls for interviewer','pass':page.locator('[data-action=nav][data-id=company],[data-action=nav][data-id=access]').count()==0});b.close()
 except Exception:
  if page:
   try:page.screenshot(path=str(a.out/'capture-error.png'));(a.out/'capture-error.txt').write_text(page.locator('body').inner_text())
   except Exception:pass
  raise
 finally:
  for s in servers:s.shutdown()
  (a.out/'captures.json').write_text(json.dumps({'scope':'Actual Chromium with isolated SQL simulation; no production requests, no hosted or physical-device certification.','screens':shots,'checks':checks},ensure_ascii=False,indent=2))
 assert checks and all(c['pass'] for c in checks),checks
if __name__=='__main__':main()
