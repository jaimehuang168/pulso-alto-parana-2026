"""Read-only public checks; no hosted login, SQL mutation or synthetic survey writes."""
from pathlib import Path
import json,hashlib,urllib.request,os,re,concurrent.futures
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[2]
# The previous checks remain intact; only the newly accepted runtime changes.
src=(ROOT/'docs/training314/verify_published.py').read_text().replace('74a46e6ba3698646f7f50ab254c2a60ef39353a2','940859a1ec8d254b8eb62c29d3aee6443237b9b4')
exec(compile(src,'existing-identity-media-public-checks','exec'),{'__name__':'__main__'})
BASE='https://jaimehuang168.github.io/pulso-alto-parana-2026/';checks=[];OUT=Path('evidence');OUT.mkdir(exist_ok=True)
def check(name,ok):
 checks.append({'name':name,'pass':bool(ok)});assert ok,name
def read(route):
 assert '..' not in route and not route.startswith('/')
 with urllib.request.urlopen(BASE+route+'?verified='+os.environ['GITHUB_SHA'],timeout=90) as r:return r.read()
try:
 release=json.loads(read('company-release.json'));check('Server deployment is not falsely claimed',release['required_backend_module']==15 and release['backend_deployment_completed'] is False)
 manifest=json.loads(read('ingreso/files.json'));check('Exact new guide edition',manifest['edition']=='personal-phone-015')
 def verify(item):
  name,sha=item;assert re.fullmatch('[A-Za-z0-9_./-]+',name);return name,hashlib.sha256(read('ingreso/'+name)).hexdigest()==sha
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
  for name,ok in pool.map(verify,manifest['files'].items()):check('New media hash '+name,ok)
 media=json.loads(read('ingreso/tutorials.json'))
 with sync_playwright() as p:
  browser=p.chromium.launch();page=browser.new_page(viewport={'width':390,'height':844});errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
  for route in ['v3/manual-simple.html','ingreso/index.html']:
   check('New guide route '+route,page.goto(BASE+route).status==200);check('22 illustrated steps '+route,page.locator('article.step').count()==22)
   page.locator('img').evaluate_all('(xs)=>xs.forEach(x=>x.loading="eager")');page.wait_for_function('[...document.images].every(x=>x.complete&&x.naturalWidth>0)',timeout=90000)
   check('All corresponding pictures '+route,True);check('Only Spanish '+route,not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',page.locator('body').inner_text()))
   for width in [320,390,768,1440]:
    page.set_viewport_size({'width':width,'height':900});check(str(width)+'px guide fits '+route,page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  page.set_viewport_size({'width':390,'height':844});page.locator('[id="paso-U1.1"]').scroll_into_view_if_needed();page.screenshot(path=str(OUT/'personal-guide-mobile.png'))
  for route in ['v3/manual-es.html','tutoriales/','tutoriales/manual.html']:
   page.goto(BASE+route);check('Old-flow instructions carry new guide notice '+route,page.locator('[data-personal-notice]').count()==1)
  page.goto(BASE+'ingreso/videos.html');page.locator('#usuarios video').wait_for(timeout=30000);check('Two new narrated videos',page.locator('video').count()==2)
  for v in media['videos']:
   card=page.locator('#'+v['id']);video=card.locator('video');video.evaluate('(v)=>v.load()')
   page.wait_for_function('(id)=>document.querySelector("#"+id+" video").readyState>=1',arg=v['id'],timeout=60000)
   check(v['id']+' new duration',abs(video.evaluate('(v)=>v.duration')-v['duration_seconds'])<1)
   index=min(2,len(v['chapters'])-1);target=v['chapters'][index]['start'];card.locator('.chapters button').nth(index).click()
   page.wait_for_function('([id,t])=>{const v=document.querySelector("#"+id+" video");return !v.paused&&!v.seeking&&v.readyState>=2&&Math.abs(v.currentTime-t)<3}',arg=[v['id'],target],timeout=60000)
   video.evaluate('(v)=>v.pause()');check(v['id']+' actual chapter playback',abs(video.evaluate('(v)=>v.currentTime')-target)<3)
   video.evaluate('(v)=>v.textTracks[0].mode="hidden"');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").textTracks[0].cues?.length>0',arg=v['id'],timeout=30000)
   check(v['id']+' captions match',video.evaluate('(v)=>v.textTracks[0].cues.length')==v['checks']['caption_cues'])
  for width in [320,390,768,1440]:
   page.set_viewport_size({'width':width,'height':900});check(str(width)+'px player fits',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
  check('No new JavaScript errors',not errors);browser.close()
finally:
 result={'scope':'Public static routes, files, guide images and headless video playback; no production account creation, authentication or SQL changes.','source_commit':os.environ['GITHUB_SHA'],'passed':sum(x['pass'] for x in checks),'failed':sum(not x['pass'] for x in checks),'checks':checks}
 (OUT/'simple-published.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
