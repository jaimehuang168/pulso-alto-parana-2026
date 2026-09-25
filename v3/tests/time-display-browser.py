"""Actual Chromium/WebKit official 2026 time and exported timestamps; no backend requests."""
import pathlib,json,threading,http.server,functools,datetime
from playwright.sync_api import sync_playwright
R=pathlib.Path(__file__).resolve().parents[2];out=R/'audit-evidence/time-browser';out.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 extensions_map={**http.server.SimpleHTTPRequestHandler.extensions_map,'.mjs':'text/javascript'}
 def log_message(self,*a):pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',8053),functools.partial(Quiet,directory=str(R/'web')));threading.Thread(target=s.serve_forever,daemon=True).start();checks=[]
try:
 with sync_playwright() as p:
  for engine in ['chromium','webkit']:
   browser=getattr(p,engine).launch();ctx=browser.new_context(viewport={'width':1920,'height':1080},accept_downloads=True);page=ctx.new_page()
   page.clock.set_fixed_time(datetime.datetime(2026,9,25,18,4,25,tzinfo=datetime.timezone.utc));ctx.route('**/*.supabase.co/**',lambda r:r.abort())
   page.goto('http://127.0.0.1:8053/live-demo/');page.locator('.city-card').first.wait_for()
   actual=page.locator('#server-clock').inner_text()
   assert actual.strip()=='15:04:25',engine+' displayed '+actual
   checks.append({'name':engine+' 2026-09-25T18:04:25Z displays 15:04:25','pass':True});page.screenshot(path=str(out/(engine+'-time-corrected.png')),full_page=True)
   with page.expect_download() as d:page.locator('#csv').click()
   dest=out/(engine+'-snapshot.csv');d.value.save_as(dest)
   assert '2026-09-25T18:04:25' in dest.read_text('utf-8-sig')
   checks.append({'name':engine+' CSV retains source UTC timestamp','pass':True});ctx.close();browser.close()
except Exception as e:
 checks.append({'name':'Time display browser execution','pass':False,'error':str(e)[:500]});raise
finally:
 s.shutdown();(out/'results.json').write_text(json.dumps({'scope':'Actual browser clock rendering and CSV with fixed synthetic time; no production requests','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks},indent=2))
