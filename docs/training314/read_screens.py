"""Read visible training screens without submitting forms or contacting hosted services."""
import argparse,functools,http.server,json,threading,re
from pathlib import Path
from playwright.sync_api import sync_playwright
ap=argparse.ArgumentParser();ap.add_argument('--demo',required=True);ap.add_argument('--login',required=True);ap.add_argument('--out',required=True);args=ap.parse_args();out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
servers=[]
for folder,port in [(args.demo,8063),(args.login,8064)]:
 server=http.server.ThreadingHTTPServer(('127.0.0.1',port),functools.partial(Quiet,directory=folder));threading.Thread(target=server.serve_forever,daemon=True).start();servers.append(server)
shots={};checks=[]
with sync_playwright() as p:
 browser=p.chromium.launch();ctx=browser.new_context(viewport={'width':1320,'height':900});ctx.route('**/*',lambda r:r.continue_() if r.request.url.startswith(('http://127.0.0.1:8063/','http://127.0.0.1:8064/','data:','blob:')) else r.abort());page=ctx.new_page()
 def idle():page.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'");page.wait_for_timeout(200)
 def action(name,value=None):
  idle();page.locator('[data-action="'+name+'"]'+('[data-id="'+value+'"]' if value else '')+':visible').first.click();idle()
 def nav(name):
  parent={'tasks':'people','access':'people','catalog':'company','imports':'company','exports':'company','settings':'company','review':'registry','paper':'registry'}
  if not page.locator('[data-action=nav][data-id="'+name+'"]:visible').count():action('nav',parent.get(name,name))
  action('nav',name)
 def shot(name,selector=None):
  idle();text=page.locator('body').inner_text();assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',text);assert page.evaluate('document.documentElement.scrollWidth<=innerWidth+1')
  target=page.locator(selector).first if selector else page;target.screenshot(path=str(out/(name+'.png')));origin=page.locator(selector).first.bounding_box() if selector else {'x':0,'y':0};fields=[]
  for el in page.locator('input:not([type=hidden]),textarea,select,button,a,summary,[data-session-identity]').all():
   if el.is_visible():
    b=el.bounding_box();fields.append({'name':el.get_attribute('name'),'id':el.get_attribute('id'),'action':el.get_attribute('data-action'),'label':el.inner_text()[:100],'x':b['x']-origin['x'],'y':b['y']-origin['y'],'w':b['width'],'h':b['height']})
  shots[name]={'file':name+'.png','focus':selector,'fields':fields,'text':text};print(name,flush=True)
 try:
  page.goto('http://127.0.0.1:8064/');page.locator('#login-form').wait_for();shot('login');shot('login_form','#login-form')
  page.goto('http://127.0.0.1:8063/');page.get_by_role('button',name='Admin de empresa',exact=True).wait_for(timeout=120000);page.get_by_role('button',name='Admin de empresa',exact=True).click();page.get_by_role('heading',name='Resultados',exact=True).wait_for();shot('results');shot('identity','.topbar')
  for width in [320,390,768,1320]:
   page.set_viewport_size({'width':width,'height':900});shot('identity_'+str(width));checks.append({'name':'Identity and layout '+str(width),'pass':page.locator('[data-session-identity]').is_visible()})
  page.set_viewport_size({'width':1320,'height':900})
  for screen in ['company','catalog','points','people','tasks','access','imports','exports','settings','paper','review','guide']:
   nav(screen);shot(screen)
   forms={'company':'#company-form','settings':'#operation-form','imports':'#import-form','exports':'#export-form','paper':'#paper-form'}
   if screen in forms:shot(screen+'_form',forms[screen])
   commands={'catalog':['questionnaire-new'],'points':['station-new','point-new','station-edit'],'people':['person-new','person-detail'],'tasks':['task-new'],'access':['access-new','actor-rename','grant-new','actor-role']}
   for name in commands.get(screen,[]):
    if page.locator('[data-action="'+name+'"]:visible').count():
     action(name);shot(name,'.modal');action('close-modal')
  action('password');shot('password','.modal');action('close-modal');action('logout');checks.append({'name':'Logout removes identity','pass':page.locator('[data-session-identity]').count()==0})
  page.set_viewport_size({'width':430,'height':900});page.get_by_role('button',name='Viewer CDE',exact=True).click();idle();shot('viewer');checks.append({'name':'Role switch shows current identity','pass':page.locator('[data-session-identity]').is_visible()});action('logout');page.get_by_role('button',name='Encuestador CDE',exact=True).click();page.locator('#vault-form').wait_for();shot('protection');shot('protection_form','#vault-form')
 finally:
  (out/'screens.json').write_text(json.dumps({'scope':'Read-only isolated demonstration; no submitted forms, no production access','screens':shots,'checks':checks},ensure_ascii=False,indent=2));browser.close()
for server in servers:server.shutdown()
assert checks and all(c['pass'] for c in checks)
