"""Read-only published identity UI and matched illustrated media verification."""
from pathlib import Path
import concurrent.futures,hashlib,json,os,re,time,urllib.request,urllib.error
from playwright.sync_api import sync_playwright
BASE='https://jaimehuang168.github.io/pulso-alto-parana-2026/'
SHA=os.environ['GITHUB_SHA'];OUT=Path('evidence');OUT.mkdir(exist_ok=True);checks=[]
def check(name,ok):
    checks.append({'name':name,'pass':bool(ok)})
    assert ok,name
def read(route):
    assert not route.startswith('/') and '..' not in route
    with urllib.request.urlopen(BASE+route+'?verified='+SHA,timeout=90) as r:return r.read()
try:
    for _ in range(30):
        try:
            release=json.loads(read('company-release.json'));m=json.loads(read('tutoriales/tutorials.json'))
            if release['source_commit']==SHA and m['edition']=='visual-r2' and m['render_run']==36418459043:break
        except Exception:pass
        time.sleep(3)
    else:raise RuntimeError('Current release and illustrated media not visible together')
    check('Current reviewed identity runtime',release['accepted_runtime']=='74a46e6ba3698646f7f50ab254c2a60ef39353a2')
    for route,sha in release['files'].items():check('Published App hash '+route,hashlib.sha256(read(route)).hexdigest()==sha)
    files=json.loads(read('tutoriales/files.json'))['files']
    def match(item):
        name,sha=item;assert re.fullmatch('[A-Za-z0-9_./-]+',name)
        return name,hashlib.sha256(read('tutoriales/'+name)).hexdigest()==sha
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for name,ok in pool.map(match,files.items()):check('Approved media hash '+name,ok)
    for route in ['v3/manual-es-zh.html','v3-demo/manual-es-zh.html','pruebas/ensayo/v3/manual-es-zh.html','pruebas/guia-zh.html']:
        try:read(route);status=200
        except urllib.error.HTTPError as e:status=e.code
        check('Private route absent '+route,status==404)
    with sync_playwright() as p:
        browser=p.chromium.launch();ctx=browser.new_context(viewport={'width':1440,'height':1024});page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        for route in ['', 'v3/']:
            check('Login route '+route,page.goto(BASE+route).status==200);page.locator('#login-form').wait_for(timeout=30000)
            check('No previous identity on login '+route,page.locator('[data-session-identity]').count()==0)
        for route,sel in [('live/','#access:not([hidden]) #login-form'),('live/control.html','#access:not([hidden]) #login')]:
            check('Protected live entry '+route,page.goto(BASE+route).status==200);page.locator(sel).wait_for(timeout=20000)
        ctx.route('**/*.supabase.co/**',lambda r:r.abort())
        page.goto(BASE+'v3-demo/');page.get_by_role('button',name='Admin de empresa',exact=True).wait_for(timeout=120000);page.get_by_role('button',name='Admin de empresa',exact=True).click();page.get_by_role('heading',name='Resultados',exact=True).wait_for(timeout=45000)
        check('One visible signed-in identity',page.locator('[data-session-identity]:visible').count()==1)
        name=page.locator('[data-session-name]').inner_text().strip();check('Current name displayed',bool(name))
        check('Five work areas retained',page.locator('.sidebar nav [data-group]').count()==5)
        check('Four independent city cards',page.locator('.city-card').count()==4)
        check('Spanish labels without privileged-role banner',not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',page.locator('body').inner_text()))
        page.screenshot(path=str(OUT/'session-desktop.png'),full_page=False)
        for width in [320,390,768,1440]:
            page.set_viewport_size({'width':width,'height':900});check(str(width)+'px identity fits',page.locator('[data-session-name]').inner_text().strip()==name and page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
        page.set_viewport_size({'width':390,'height':844});page.screenshot(path=str(OUT/'session-mobile.png'))
        page.locator('[data-action=logout]:visible').first.click()
        page.locator('#login-form').wait_for(timeout=20000);check('Logout removes visible identity',page.locator('[data-session-identity]').count()==0)
        for route in ['v3/manual-es.html','tutoriales/manual.html']:
            check('Illustrated manual '+route,page.goto(BASE+route).status==200)
            check('26 chapters and 147 steps '+route,page.locator('section[id^=s]').count()==26 and page.locator('article.step').count()==147)
            page.locator('img').evaluate_all('(xs)=>xs.forEach(x=>x.loading="eager")');page.wait_for_function('[...document.images].every(x=>x.complete&&x.naturalWidth>0)',timeout=90000)
            check('All corresponding images resolve '+route,True)
            check('Public manual is Spanish only '+route,not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',page.locator('body').inner_text()))
        for width in [320,390,768,1440]:
            page.set_viewport_size({'width':width,'height':900});check(str(width)+'px illustrated manual fits',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
        page.locator('[id="paso-03.2"]').scroll_into_view_if_needed();page.screenshot(path=str(OUT/'manual-latest.png'))
        page.goto(BASE+'tutoriales/');page.locator('#usuarios video').wait_for(timeout=30000)
        check('Two videos and 26 chapters',page.locator('video').count()==2 and page.locator('.chapters button').count()==26)
        for v in m['videos']:
            card=page.locator('#'+v['id']);video=card.locator('video');video.evaluate('(v)=>v.load()');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").readyState>=1',arg=v['id'],timeout=60000)
            check(v['id']+' duration matches',abs(video.evaluate('(v)=>v.duration')-v['duration_seconds'])<1)
            target=v['chapters'][2]['start'];card.locator('.chapters button').nth(2).click()
            page.wait_for_function('([id,t])=>{const v=document.querySelector("#"+id+" video");return !v.paused&&!v.seeking&&v.readyState>=2&&Math.abs(v.currentTime-t)<3}',arg=[v['id'],target],timeout=60000)
            video.evaluate('(v)=>v.pause()');check(v['id']+' precise chapter playback',abs(video.evaluate('(v)=>v.currentTime')-target)<3)
            card.locator('select').select_option('1.25');check(v['id']+' speed',video.evaluate('(v)=>v.playbackRate')==1.25)
            video.evaluate('(v)=>v.textTracks[0].mode="hidden"');page.wait_for_function('(id)=>document.querySelector("#"+id+" video").textTracks[0].cues?.length>0',arg=v['id'],timeout=30000)
            check(v['id']+' subtitles',video.evaluate('(v)=>v.textTracks[0].cues.length')==v['checks']['caption_cues'])
        for width in [320,390,768,1440]:
            page.set_viewport_size({'width':width,'height':900});check(str(width)+'px player fits',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
        page.screenshot(path=str(OUT/'tutorials-latest.png'));check('No page JavaScript errors',not errors);browser.close()
except Exception as e:
    checks.append({'name':'Published verification execution','pass':False,'error':str(e)[:800]});raise
finally:
    result={'scope':'Read-only static hashes, isolated demo and headless Chromium media. No production login, survey write or physical-device certification.','source_commit':SHA,'passed':sum(c['pass'] for c in checks),'failed':sum(not c['pass'] for c in checks),'checks':checks}
    (OUT/'identity-illustrated-published.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
