"""Real playback on an HTTP Range server; not physical-device acceptance."""
from pathlib import Path
import argparse,functools,http.server,json,os,re,threading,urllib.request
from playwright.sync_api import sync_playwright
ap=argparse.ArgumentParser();ap.add_argument('folder',type=Path);a=ap.parse_args();data=json.loads((a.folder/'tutorials.json').read_text());checks=[]
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
 def send_head(self):
  self.byte_range=None
  header=self.headers.get('Range');path=Path(self.translate_path(self.path))
  if not header or not path.is_file():return super().send_head()
  m=re.fullmatch(r'bytes=(\d*)-(\d*)',header)
  if not m or not any(m.groups()):self.send_error(416);return None
  size=path.stat().st_size
  start=int(m[1]) if m[1] else max(0,size-int(m[2]));end=min(size-1,int(m[2])) if m[1] and m[2] else size-1
  if start<0 or end<start or start>=size:
   self.send_response(416);self.send_header('Content-Range',f'bytes */{size}');self.send_header('Content-Length','0');self.end_headers();return None
  f=path.open('rb');f.seek(start);self.byte_range=(start,end);self.send_response(206);self.send_header('Content-Type',self.guess_type(str(path)));self.send_header('Content-Range',f'bytes {start}-{end}/{size}');self.send_header('Content-Length',str(end-start+1));self.end_headers();return f
 def end_headers(self):self.send_header('Accept-Ranges','bytes');self.send_header('Cache-Control','no-store');super().end_headers()
 def copyfile(self,source,outputfile):
  try:
   if self.byte_range is None:return super().copyfile(source,outputfile)
   remaining=self.byte_range[1]-self.byte_range[0]+1
   while remaining:
    block=source.read(min(65536,remaining))
    if not block:break
    outputfile.write(block);remaining-=len(block)
  except (BrokenPipeError,ConnectionResetError):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8073),functools.partial(Quiet,directory=str(a.folder)));threading.Thread(target=srv.serve_forever,daemon=True).start()
def check(name,ok):
 checks.append({'name':name,'pass':bool(ok)});assert ok,name
page=None
try:
 for v in data['videos']:
  req=urllib.request.Request('http://127.0.0.1:8073/'+v['file'],headers={'Range':'bytes=0-15'})
  with urllib.request.urlopen(req) as response:check(v['id']+' actual HTTP 206 byte ranges',response.status==206 and response.read()==(a.folder/v['file']).read_bytes()[:16])
 with sync_playwright() as p:
  browser=p.chromium.launch();ctx=browser.new_context(viewport={'width':1440,'height':1050});page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)));page.goto('http://127.0.0.1:8073/');page.locator('article').nth(1).wait_for(timeout=30000);check('Two guides loaded',page.locator('article').count()==2)
  for v in data['videos']:
   card=page.locator('#'+v['id']);video=card.locator('video');video.evaluate('(v)=>v.load()');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").readyState>=1',arg=v['id'],timeout=60000)
   check(v['id']+' duration',abs(video.evaluate('(v)=>v.duration')-v['duration_seconds'])<1)
   card.locator('.chapters button').nth(2).click();page.wait_for_function('(x)=>{const v=document.querySelector("#"+x.id+" video");return !v.paused&&!v.seeking&&v.readyState>=2&&Math.abs(v.currentTime-x.time)<3}',arg={'id':v['id'],'time':v['chapters'][2]['start']},timeout=30000)
   check(v['id']+' accurate chapter seek',abs(video.evaluate('(v)=>v.currentTime')-v['chapters'][2]['start'])<3)
   card.locator('select').select_option('1.25');check(v['id']+' playback speed',video.evaluate('(v)=>v.playbackRate')==1.25)
   video.evaluate('(v)=>{v.textTracks[0].mode="hidden";}');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").textTracks[0].cues?.length>0',arg=v['id'],timeout=20000)
   check(v['id']+' synchronized subtitle cues',video.evaluate('(v)=>v.textTracks[0].cues.length')==v['checks']['caption_cues']);video.evaluate('(v)=>v.pause()')
   for key in ['file','poster','subtitles','srt','transcript']:check(v['id']+' local '+key,(a.folder/v[key]).is_file())
  page.screenshot(path=str(a.folder/'player-desktop.png'),full_page=False)
  for width in [320,390,768]:
   page.set_viewport_size({'width':width,'height':844});check(str(width)+'px no horizontal overflow',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  page.set_viewport_size({'width':390,'height':844});page.locator('#usuarios').scroll_into_view_if_needed();page.screenshot(path=str(a.folder/'player-mobile.png'),full_page=False);check('No browser JavaScript errors',not errors);browser.close()
except Exception as e:
 checks.append({'name':'Actual player verification','pass':False,'error':str(e)[:1500]})
 if page:
  try:
   state=page.locator('video').evaluate_all('(vs)=>vs.map(v=>({src:v.currentSrc,time:v.currentTime,ready:v.readyState,seeking:v.seeking,paused:v.paused,error:v.error?.message,seekable:Array.from({length:v.seekable.length},(_,i)=>[v.seekable.start(i),v.seekable.end(i)])}))');(a.folder/'player-error.json').write_text(json.dumps(state));page.screenshot(path=str(a.folder/'player-error.png'))
  except Exception:pass
 raise
finally:
 srv.shutdown();(a.folder/'player-checks.json').write_text(json.dumps({'scope':'Headless Chromium and generated MP4 files on an isolated HTTP Range server; not Android/iPhone hardware.','passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks},ensure_ascii=False,indent=2))
