"""Read-only checks of public tutorial files; never log in or write production data."""
from pathlib import Path
import argparse,hashlib,json,re,time,urllib.request
from playwright.sync_api import sync_playwright
ap=argparse.ArgumentParser();ap.add_argument('--source-commit',required=True);ap.add_argument('--render-commit',required=True);ap.add_argument('--render-run',required=True);ap.add_argument('--out',type=Path,default=Path('evidence'));a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
base='https://jaimehuang168.github.io/pulso-alto-parana-2026/';checks=[]
def check(name,ok):
 checks.append({'name':name,'pass':bool(ok)});assert ok,name

def read(route):
 assert '..' not in route
 with urllib.request.urlopen(base+route+'?tutorial_check='+a.source_commit,timeout=60) as r:return r.read()
for attempt in range(30):
 try:
  release=json.loads(read('company-release.json'));manifest=json.loads(read('tutoriales/tutorials.json'))
  if release['source_commit']==a.source_commit and manifest['build_commit']==a.render_commit and str(manifest['render_run'])==a.render_run:break
 except Exception:pass
 time.sleep(4)
else:raise RuntimeError('Expected current application and tutorial release not both visible')
try:
 check('Current main application release',release['source_commit']==a.source_commit and release['version']=='3.1.3')
 check('Approved tutorial build',manifest['build_commit']==a.render_commit and str(manifest['render_run'])==a.render_run)
 for name,expected in manifest['files'].items():
  assert re.fullmatch('[A-Za-z0-9_.-]+',name)
  check('Published content hash '+name,hashlib.sha256(read('tutoriales/'+name)).hexdigest()==expected)
 with sync_playwright() as p:
  browser=p.chromium.launch();ctx=browser.new_context(viewport={'width':1440,'height':1024});ctx.route('**/*.supabase.co/**',lambda r:r.abort());page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)));response=page.goto(base+'tutoriales/');check('Public tutorial route',response.status==200);page.locator('article').nth(1).wait_for(timeout=30000)
  check('Two videos and 32 chapters',page.locator('video').count()==2 and page.locator('.chapters button').count()==32)
  check('Spanish without owner information',not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',page.locator('body').inner_text()))
  for v in manifest['videos']:
   card=page.locator('#'+v['id']);video=card.locator('video');video.evaluate('(v)=>v.load()');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").readyState>=1',arg=v['id'],timeout=60000)
   check(v['id']+' public duration',abs(video.evaluate('(v)=>v.duration')-v['duration_seconds'])<1)
   card.locator('.chapters button').nth(2).click();page.wait_for_function('(id)=>{const v=document.querySelector("#"+id+" video");return !v.paused&&!v.seeking&&v.readyState>=2}',arg=v['id'],timeout=60000)
   check(v['id']+' chapter navigation',abs(video.evaluate('(v)=>v.currentTime')-v['chapters'][2]['start'])<20)
   card.locator('select').select_option('1.25');check(v['id']+' speed control',video.evaluate('(v)=>v.playbackRate')==1.25)
   video.evaluate('(v)=>{v.textTracks[0].mode="hidden";}');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").textTracks[0].cues?.length>0',arg=v['id'],timeout=20000);check(v['id']+' public subtitle cues',video.evaluate('(v)=>v.textTracks[0].cues.length')==v['checks']['caption_cues']);video.evaluate('(v)=>v.pause()')
  page.screenshot(path=str(a.out/'tutorials-desktop.png'),full_page=False)
  for width in [320,390,768]:
   page.set_viewport_size({'width':width,'height':844});check(str(width)+'px teaching page layout',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  page.set_viewport_size({'width':390,'height':844});page.locator('#usuarios').scroll_into_view_if_needed();page.screenshot(path=str(a.out/'tutorials-mobile.png'),full_page=False);check('No public player JavaScript errors',not errors)
  check('Manual link resolves',page.goto(base+'v3/manual-es.html').status==200);check('Spanish manual retains 26 chapters',page.locator('section[id^=s]').count()==26);check('Common app link resolves',page.goto(base+'v3/').status==200);page.locator('#login-form').wait_for(timeout=20000);browser.close()
finally:
 (a.out/'tutorials-published.json').write_text(json.dumps({'scope':'Read-only public file hashes and real headless Chromium playback. No authenticated production flow or physical-device certification.','source_commit':a.source_commit,'render_commit':a.render_commit,'render_run':a.render_run,'passed':sum(c['pass'] for c in checks),'failed':sum(not c['pass'] for c in checks),'checks':checks},ensure_ascii=False,indent=2))
print(json.dumps(checks,ensure_ascii=False,indent=2))
