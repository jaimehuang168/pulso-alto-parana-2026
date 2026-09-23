"""真實瀏覽器與 IndexedDB，模擬 Auth/RPC；所有非本機網路封鎖，沒有正式庫寫入。"""
from pathlib import Path
import functools,http.server,threading,os,json,traceback
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('LOGIN_TEST_OUTPUT',ROOT/'login-test-results'));OUT.mkdir(parents=True,exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(ROOT/'web')))
threading.Thread(target=server.serve_forever,daemon=True).start();base=f'http://127.0.0.1:{server.server_port}/'
fixture=(ROOT/'tests/fixtures/login-sdk.js').read_text();results=[]
def record(name,fn):
    try:fn();results.append({'name':name,'pass':True})
    except Exception as e:results.append({'name':name,'pass':False,'error':str(e)[:700]});print(traceback.format_exc())
    print(json.dumps(results[-1],ensure_ascii=False),flush=True)
def expect(value,message='assertion failed'):assert value,message
with sync_playwright() as pw:
 for engine in os.environ.get('LOGIN_BROWSERS','chromium,webkit').split(','):
    browser=getattr(pw,engine).launch(headless=True)
    def page_for(width=390,height=844,scenario='disabled',session=False):
        ctx=browser.new_context(viewport={'width':width,'height':height},is_mobile=width<760,has_touch=width<760,device_scale_factor=1,service_workers='block')
        page=ctx.new_page();page.set_default_timeout(6000);external=[];errors=[]
        page.on('pageerror',lambda e:errors.append(str(e)))
        def route(req):
            if not req.request.url.startswith(base):external.append(req.request.url);req.abort();return
            if req.request.url.endswith('/config.js'):req.fulfill(status=200,content_type='application/javascript',body="window.PULSO_CONFIG={supabaseUrl:'https://qa-only.example.invalid',supabasePublishableKey:'sb_publishable_fixture',allowDemo:false};")
            else:req.continue_()
        page.route('**/*',route)
        page.add_init_script(f'window.qaScenario={json.dumps(scenario)};window.qaSession={str(session).lower()};\n'+fixture)
        page.goto(base);page.locator('#login-form').wait_for();return ctx,page,external,errors
    def submit(page):
        page.locator('#login-form [name=user]').fill('VIEW-QA001');page.locator('#login-form [name=password]').fill('fixture-password-not-real')
        page.locator('#login-form [type=submit]').click();page.locator('#login-feedback:not([hidden])').wait_for();page.wait_for_timeout(180)
    for width,height in [(320,640),(390,844),(430,932),(768,1024),(1440,900)]:
        def layout(w=width,h=height):
            ctx,p,ext,errors=page_for(w,h)
            try:
                submit(p);box=p.locator('#login-feedback');r=box.bounding_box()
                expect('Cuenta no habilitada' in box.inner_text());expect(r['x']>=0 and r['x']+r['width']<=w+1,'alert clipped horizontally')
                expect(r['y']>=-1 and r['y']<h-60,'alert not scrolled into view');expect(p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'),'page overflows')
                expect(p.evaluate("document.activeElement.id==='login-feedback'"),'focus not on alert');expect(int(box.locator('p').first.evaluate('(e)=>parseFloat(getComputedStyle(e).fontSize)'))>=18)
                expect(p.locator('#login-form [name=user]').input_value()=='VIEW-QA001');expect(p.locator('#login-form [name=password]').input_value()=='','password retained')
                expect(not ext and not errors,'external request or page error');expect(p.evaluate('qaLogin.writes')==0)
                if w==390:p.screenshot(path=str(OUT/f'{engine}_disabled_mobile.png'))
            finally:ctx.close()
        record(f'{engine}: disabled login {width}x{height}',layout)
    for scenario,heading in [('wrong','No se pudo iniciar sesión'),('network','No se pudo conectar'),('unconfirmed','Correo sin confirmar'),('rate','Demasiados intentos')]:
        def failure(s=scenario,h=heading):
            ctx,p,ext,errors=page_for(scenario=s)
            try:submit(p);expect(h in p.locator('#login-feedback').inner_text());expect(not ext and not errors);expect(p.evaluate('qaLogin.writes')==0)
            finally:ctx.close()
        record(f'{engine}: {scenario} message',failure)
    def persistence():
        ctx,p,ext,errors=page_for()
        try:
            submit(p);before=p.locator('#login-feedback').inner_text();p.wait_for_timeout(6600)
            expect(p.locator('#login-feedback').is_visible());expect(p.locator('#login-feedback').inner_text()==before);expect(p.locator('.toast').count()==0,'login still relies on toast')
        finally:ctx.close()
    record(f'{engine}: notice remains after old 6-second timeout',persistence)
    def restored():
        ctx,p,ext,errors=page_for(session=True)
        try:
            p.locator('#login-feedback:not([hidden])').wait_for();expect('Cuenta no habilitada' in p.locator('#login-feedback').inner_text());expect(p.locator('.shell').count()==0);expect(not ext and not errors)
        finally:ctx.close()
    record(f'{engine}: revoked saved session on reload',restored)
    def revoke_and_recover():
        ctx,p,ext,errors=page_for(scenario='active',session=False)
        try:
            p.locator('[name=user]').fill('VIEW-QA001');p.locator('[name=password]').fill('fixture');p.locator('#login-form [type=submit]').click()
            p.get_by_text('Acceso a resultados pendiente',exact=True).wait_for();expect(p.locator('[data-screen=settings]').count()==0)
            p.evaluate("qaLogin.scenario='disabled';document.dispatchEvent(new Event('visibilitychange'))")
            p.locator('#login-feedback:not([hidden])').wait_for();expect(p.locator('.shell').count()==0)
            p.evaluate("qaLogin.scenario='active'");p.locator('[name=password]').fill('fixture');p.locator('#login-form [type=submit]').click()
            p.get_by_text('Acceso a resultados pendiente',exact=True).wait_for();expect(p.locator('#login-feedback').count()==0);expect(not ext and not errors);expect(p.evaluate('qaLogin.writes')==0)
        finally:ctx.close()
    record(f'{engine}: background revocation and successful retry clears notice',revoke_and_recover)
    def outbox():
        ctx,p,ext,errors=page_for()
        try:
            p.evaluate("async()=>{const s=new PulsoCore.Store();await s.open();await s.put('outbox',{id:'qa-local-only',owner:'qa-browser-user',environment:'https://qa-only.example.invalid',event:{captured_at:'2026-09-23T00:00:00Z'},status:'pending'});}")
            submit(p);expect(p.evaluate("async()=>{const s=new PulsoCore.Store();return !!(await s.get('outbox','qa-local-only'));}"))
            p.reload();p.locator('#login-form').wait_for();expect(p.evaluate("async()=>{const s=new PulsoCore.Store();return !!(await s.get('outbox','qa-local-only'));}"))
        finally:ctx.close()
    record(f'{engine}: rejection preserves IndexedDB outbox across reload',outbox)
    def short_height():
        ctx,p,ext,errors=page_for(390,390)
        try:
            submit(p);r=p.locator('#login-feedback h3').bounding_box();expect(r['y']>=0 and r['y']+r['height']<390)
            p.set_viewport_size({'width':390,'height':844});p.wait_for_timeout(150);expect(p.locator('#login-feedback').is_visible());expect(not ext and not errors)
        finally:ctx.close()
    record(f'{engine}: short visual area then resize (not native keyboard)',short_height)
    def toast():
        ctx,p,ext,errors=page_for(320,640)
        try:
            p.evaluate("()=>{const n=document.createElement('div');n.className='toast error';n.textContent='Aviso de prueba: mensaje completo sin recortes.';document.querySelector('#toast-root').append(n);}")
            r=p.locator('.toast').bounding_box();expect(r['x']>=0 and r['x']+r['width']<=320,'toast still clipped')
        finally:ctx.close()
    record(f'{engine}: mobile floating toast stays inside screen',toast);browser.close()
server.shutdown()
summary={'scope':'Real Chromium/WebKit and IndexedDB; mocked Auth/RPC; all external network blocked. No production login or writes. Short viewport is not native iOS keyboard testing.','tests':results,'passed':sum(x['pass'] for x in results),'total':len(results)}
(OUT/'login_mobile_results.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
if any(not x['pass'] for x in results):raise SystemExit(1)
