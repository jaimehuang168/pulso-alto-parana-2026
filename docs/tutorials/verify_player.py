"""Local media playback verification; not physical-device or production acceptance."""
from pathlib import Path
import argparse,functools,http.server,json,threading
from playwright.sync_api import sync_playwright
ap=argparse.ArgumentParser();ap.add_argument('folder',type=Path);a=ap.parse_args();data=json.loads((a.folder/'tutorials.json').read_text());checks=[]
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8073),functools.partial(Quiet,directory=str(a.folder)));threading.Thread(target=srv.serve_forever,daemon=True).start()
def check(name,ok):
 checks.append({'name':name,'pass':bool(ok)});assert ok,name
try:
 with sync_playwright() as p:
  browser=p.chromium.launch();ctx=browser.new_context(viewport={'width':1440,'height':1050});page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)));page.goto('http://127.0.0.1:8073/');page.locator('article').nth(1).wait_for(timeout=30000);check('Two guides loaded',page.locator('article').count()==2)
  for v in data['videos']:
   card=page.locator('#'+v['id']);video=card.locator('video');video.evaluate('(v)=>v.load()');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").readyState>=1',arg=v['id'],timeout=60000)
   check(v['id']+' duration',abs(video.evaluate('(v)=>v.duration')-v['duration_seconds'])<1)
   card.locator('.chapters button').nth(2).click();page.wait_for_function('(id)=>{const v=document.querySelector("#"+id+" video");return !v.paused&&v.currentTime>2}',arg=v['id'],timeout=20000)
   check(v['id']+' chapter seek',abs(video.evaluate('(v)=>v.currentTime')-v['chapters'][2]['start'])<15)
   card.locator('select').select_option('1.25');check(v['id']+' playback speed',video.evaluate('(v)=>v.playbackRate')==1.25)
   video.evaluate('(v)=>{v.textTracks[0].mode="hidden";}');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").textTracks[0].cues?.length>0',arg=v['id'],timeout=20000)
   check(v['id']+' synchronized subtitle cues',video.evaluate('(v)=>v.textTracks[0].cues.length')==v['checks']['caption_cues']);video.evaluate('(v)=>v.pause()')
   for key in ['file','poster','subtitles','srt','transcript']:check(v['id']+' local '+key,(a.folder/v[key]).is_file())
  page.screenshot(path=str(a.folder/'player-desktop.png'),full_page=False)
  for width in [320,390,768]:
   page.set_viewport_size({'width':width,'height':844});check(str(width)+'px no horizontal overflow',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  page.set_viewport_size({'width':390,'height':844});page.locator('#usuarios').scroll_into_view_if_needed();page.screenshot(path=str(a.folder/'player-mobile.png'),full_page=False);check('No browser JavaScript errors',not errors);browser.close()
finally:
 srv.shutdown();(a.folder/'player-checks.json').write_text(json.dumps({'scope':'Headless Chromium and generated MP4 files on an isolated local server; not Android/iPhone hardware.','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks},ensure_ascii=False,indent=2))
