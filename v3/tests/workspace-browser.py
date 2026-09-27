"""Actual local Auth/HTTP and Chromium/WebKit UI; no hosted or physical-device claims."""
from pathlib import Path
import json,re,threading,http.server,functools,csv,io
from playwright.sync_api import sync_playwright
R=Path(__file__).resolve().parents[2];F=json.loads(Path('/tmp/pulso-company-private.json').read_text());OUT=R/'v3/evidence/workspace-browser';OUT.mkdir(parents=True,exist_ok=True);checks=[]
assert F['url'].startswith('http://127.0.0.1:')
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8044),functools.partial(Quiet,directory=str(R/'web')));threading.Thread(target=srv.serve_forever,daemon=True).start()
def check(name,ok):
 assert ok,name
 checks.append({'name':name,'pass':True})
def idle(p):p.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'")
def action(p,name,id=None):
 idle(p);p.locator('[data-action="'+name+'"]'+('[data-id="'+id+'"]' if id else '')+':visible').first.click();idle(p)
def nav(p,name):
 group={'tasks':'people','access':'people','catalog':'company','imports':'company','exports':'company','settings':'company','review':'registry','paper':'registry','task':'capture'}
 if not p.locator('[data-action=nav][data-id="'+name+'"]:visible').count():action(p,'nav',group.get(name,name))
 action(p,'nav',name)
def login(p,cred):
 p.goto('http://127.0.0.1:8044/v3/');p.locator('#login-form [name=code]').fill(cred['code']);p.locator('#login-form [name=password]').fill(cred['password']);p.locator('#login-form button[type=submit]').click();p.get_by_role('heading',name='Resultados',exact=True).wait_for(timeout=30000);idle(p)
try:
 with sync_playwright() as P:
  for engine in ['chromium','webkit']:
   browser=getattr(P,engine).launch();ctx=browser.new_context(viewport={'width':1440,'height':1040},accept_downloads=True);p=ctx.new_page();api_errors=[]
   p.on('pageerror',lambda e:api_errors.append(str(e)[:200]))
   login(p,F['company'])
   check(engine+' five desktop areas',p.locator('.sidebar nav [data-group]').count()==5)
   check(engine+' four city cards in catalog order',p.locator('.city-card').evaluate_all('(a)=>a.map(x=>x.dataset.city)')==['cde','minga','hernandarias','franco'])
   text=p.locator('body').inner_text();check(engine+' Spanish interface without owner or technical role panel',not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',text))
   p.screenshot(path=str(OUT/(engine+'-results.png')),full_page=True)
   for width in [320,390,768,1024,1920]:
    p.set_viewport_size({'width':width,'height':1000});check(engine+' results reflow '+str(width),p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   p.set_viewport_size({'width':390,'height':844});check(engine+' five mobile work buttons',p.locator('.mobilebottom [data-group]:visible').count()==5);p.screenshot(path=str(OUT/(engine+'-mobile.png')),full_page=True)
   action(p,'filter-city','cde');check(engine+' city filter excludes other city cards',p.locator('.city-card').count()==1 and p.locator('.city-card').get_attribute('data-city')=='cde')
   options=p.locator('#workspace-station option').evaluate_all('(a)=>a.map(x=>x.value).filter(Boolean)');assert options
   p.locator('#workspace-station').select_option(options[0]);idle(p);check(engine+' selected location persists',p.locator('#workspace-station').input_value()==options[0])
   action(p,'filter-city','minga');check(engine+' changing city clears old location',p.locator('#workspace-station').input_value()=='' and p.locator('#workspace-point').input_value()=='')
   action(p,'board-pause');check(engine+' pause does not imply stopped collection','La recepción de encuestas continúa.' in p.locator('body').inner_text());action(p,'board-pause')
   nav(p,'points');check(engine+' location cards preserve city filter',p.locator('#workspace-station option').count()>0 and p.locator('.city-tabs [data-id=minga]').get_attribute('aria-pressed')=='true');action(p,'filter-reset')
   check(engine+' point controls visible',p.locator('.point-work').count()>0);p.screenshot(path=str(OUT/(engine+'-locales.png')),full_page=True)
   nav(p,'people');check(engine+' team table includes name task receipt signal',all(x in p.locator('.responsive-table thead').text_content() for x in ['Persona','Tarea actual','Recibidas','Señal reciente']))
   action(p,'person-detail');check(engine+' person details keep assignment history','Historial de asignaciones' in p.locator('.modal').inner_text());action(p,'close-modal');p.screenshot(path=str(OUT/(engine+'-equipo.png')),full_page=True)
   nav(p,'access');action(p,'access-new');check(engine+' ordinary admin still cannot create administrators',p.locator('option[value=admin]').count()==0);action(p,'close-modal')
   nav(p,'registry');p.locator('.filter-summary').filter(has_text='coincidencias en').wait_for(timeout=30000);txt=p.locator('.filter-summary').filter(has_text='coincidencias en').inner_text();m=re.search(r'([\d.]+) coincidencias en ([\d.]+)',txt);assert m
   matches,total=[int(x.replace('.','')) for x in m.groups()];check(engine+' complete registry is not first UI page',matches==total and total>0 and p.locator('.responsive-table tbody tr').count()==min(50,total))
   with p.expect_download() as dl:action(p,'registry-export')
   content=Path(dl.value.path()).read_text(encoding='utf-8-sig');rows=list(csv.reader(io.StringIO(content)));check(engine+' CSV contains every matching row plus metadata and header',len(rows)==total+2)
   check(engine+' exported internal rows are marked internal',rows[0][0]=='USO INTERNO');p.screenshot(path=str(OUT/(engine+'-registro.png')),full_page=True)
   p.locator('#record-from').fill('2100-01-01T00:00');p.locator('#record-from').press('Tab');idle(p);check(engine+' received-date filter applies to entire snapshot','0 coincidencias' in p.locator('.filter-summary').filter(has_text='coincidencias en').inner_text())
   action(p,'filter-reset');nav(p,'company');check(engine+' company edit form remains available',p.locator('#company-form').count()==1);check(engine+' no activation form or private manual links',p.locator('[data-action=activate],[data-action=company-activate],#company-readiness-form,a[href*="manual-es-zh"]').count()==0)
   check(engine+' deleted bilingual web route is not served',ctx.request.get('http://127.0.0.1:8044/v3/manual-es-zh.html').status==404)
   manual=ctx.request.get('http://127.0.0.1:8044/v3/manual-es.html').text();check(engine+' public manual complete and Spanish only',manual.count('<section id="s')==26 and not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',manual))
   check(engine+' no browser execution errors',not api_errors);ctx.close();browser.close()
except Exception as e:
 checks.append({'name':'Workspace browser flow','pass':False,'error':str(e)[:800]})
 try:p.screenshot(path=str(OUT/'FAILURE.png'),full_page=True)
 except:pass
finally:
 srv.shutdown();d={'scope':'Real local Auth and HTTP in Chromium/WebKit. Synthetic data only. Not physical phones or production.','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks};(OUT/'results.json').write_text(json.dumps(d,ensure_ascii=False,indent=2));print(json.dumps(d,ensure_ascii=False,indent=2))
 if d['failed']:raise SystemExit(1)
