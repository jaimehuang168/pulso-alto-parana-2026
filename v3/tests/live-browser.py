"""Actual HTTP browser test of the synthetic monitor. No production login or writes."""
import json,os,pathlib,threading,http.server,functools,contextlib
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'v3/evidence/live-browser';OUT.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',8851),functools.partial(Quiet,directory=str(ROOT/'web')))
threading.Thread(target=server.serve_forever,daemon=True).start()
results=[]
def check(name,value):
 if not value:raise AssertionError(name)
 results.append({'name':name,'pass':True});print('PASS',name,flush=True)
with sync_playwright() as play:
 try:
  for engine in ['chromium','webkit']:
   browser=getattr(play,engine).launch();ctx=browser.new_context(viewport={'width':1920,'height':1080},accept_downloads=True);page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)));page.clock.install()
   page.route('**/*.supabase.co/**',lambda route:route.abort())
   page.goto('http://127.0.0.1:8851/live-demo/',wait_until='domcontentloaded');page.locator('.city-card').first.wait_for()
   check(engine+' HTTP loads four cities without Supabase',page.locator('.city-card').count()==4)
   check(engine+' all panels and candidates visible at 1920x1080',page.evaluate("document.documentElement.scrollHeight<=innerHeight+1 && [...document.querySelectorAll('.candidate-list')].every(e=>e.scrollHeight<=e.clientHeight+1)"))
   page.screenshot(path=str(OUT/(engine+'-four.png')),full_page=True)
   before=page.locator('[data-city=cde] .metric b').first.inner_text();page.clock.fast_forward(5100);page.wait_for_timeout(60)
   check(engine+' automatic update before polling ends',before!=page.locator('[data-city=cde] .metric b').first.inner_text())
   page.locator('button[data-city=minga]').click();check(engine+' single city only',page.locator('.city-card').count()==1 and page.locator('.candidate-line').count()==4)
   page.locator('#audience').select_option('internal');page.wait_for_function("document.querySelector('.candidate-name')?.textContent.includes('FICTICIA')")
   check(engine+' internal synthetic names and Lista','Lista DEMO' in page.locator('#board').inner_text())
   page.locator('#audience').select_option('codes');page.wait_for_function("document.querySelector('.candidate-name')?.textContent.trim()==='MGA-A'")
   check(engine+' codes remove names from document','FICTICIA' not in page.locator('#board').inner_text() and 'Lista' not in page.locator('#board').inner_text())
   page.locator('#pause').click();before=page.locator('#board').inner_text();page.clock.fast_forward(12000);page.wait_for_timeout(60)
   check(engine+' paused screen frozen and labelled',before==page.locator('#board').inner_text() and 'PAUSA' in page.locator('#connection').inner_text())
   page.locator('#pause').click();page.wait_for_timeout(60);check(engine+' resume continues updates',page.locator('#pause').inner_text().strip()=='Ⅱ Pausar')
   page.locator('#rotate').click();before=page.locator('.city-card').get_attribute('data-city');page.clock.fast_forward(15100);page.wait_for_timeout(60)
   check(engine+' 15-second city rotation',page.locator('.city-card').get_attribute('data-city')!=before)
   page.locator('button[data-city=all]').click();check(engine+' manual four-city selection stops rotation',page.locator('.city-card').count()==4 and 'Rotación' in page.locator('#rotate').inner_text())
   with page.expect_download() as result:page.locator('#csv').click()
   result.value.save_as(str(OUT/(engine+'-demo.csv')));csv=(OUT/(engine+'-demo.csv')).read_text('utf-8-sig')
   check(engine+' downloaded CSV contains codes and cutoff only','DEMO' in csv and 'Nombre interno' not in csv and 'Lista interna' not in csv and 'FICTICIA' not in csv)
   with page.expect_download(timeout=20000) as result:page.locator('#png').click()
   result.value.save_as(str(OUT/(engine+'-demo.png')));check(engine+' actual PNG rendering',(OUT/(engine+'-demo.png')).stat().st_size>20000)
   for width in [320,390,430,768,1366]:
    page.set_viewport_size({'width':width,'height':900 if width>=1100 else 844});check(engine+' no horizontal overflow '+str(width),page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   page.set_viewport_size({'width':390,'height':844});page.locator('button[data-city=cde]').click();page.screenshot(path=str(OUT/(engine+'-mobile.png')),full_page=True)
   page.locator('.help summary').click();page.locator('#simulate-offline').click();page.wait_for_timeout(60)
   check(engine+' disconnected warning keeps old data distinguishable',page.locator('#notice').is_visible() and page.locator('.candidate-line').count()==2)
   page.clock.fast_forward(16000);page.wait_for_timeout(60);check(engine+' persistent stale-data label','SIN ACTUALIZAR' in page.locator('#notice').inner_text())
   page.locator('#simulate-offline').click();page.wait_for_timeout(60);check(engine+' reconnection refreshes status','DEMO EN MOVIMIENTO' in page.locator('#connection').inner_text())
   page.locator('#audience').select_option('released');page.wait_for_function("document.querySelector('#audience').value==='released' && document.querySelector('.city-card')")
   page.locator('#pause').click();page.clock.fast_forward(16000);page.wait_for_timeout(60);check(engine+' released view expires when not reconfirmed',page.locator('.candidate-line').count()==0)
   check(engine+' no uncaught JavaScript errors',not errors);ctx.close();browser.close()
 except Exception as e:
  results.append({'name':'Browser execution','pass':False,'error':str(e)[:900]});print('FAIL',str(e),flush=True)
  with contextlib.suppress(Exception):page.screenshot(path=str(OUT/'failure.png'),full_page=True)
 finally:
  server.shutdown();(OUT.parent/'live-http-browser.json').write_text(json.dumps({'scope':'Real Chromium/WebKit HTTP synthetic monitor and downloads. Not native Auth, hosted database or physical devices.','passed':sum(r['pass'] for r in results),'failed':sum(not r['pass'] for r in results),'results':results},ensure_ascii=False,indent=2))
if any(not r['pass'] for r in results):raise SystemExit(1)
