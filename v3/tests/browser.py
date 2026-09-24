"""Chromium/WebKit: actual browser UI and encrypted storage; localhost only."""
import json, os, pathlib, threading, http.server, time, base64, contextlib
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'evidence'/'browser';OUT.mkdir(parents=True,exist_ok=True)
results=[]
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
    def end_headers(self):
        self.send_header('Cache-Control','no-store');super().end_headers()
def server(folder,port):
    import functools
    srv=http.server.ThreadingHTTPServer(('127.0.0.1',port),functools.partial(Quiet,directory=str(folder)))
    threading.Thread(target=srv.serve_forever,daemon=True).start();return srv
servers=[server(ROOT/'preview',8043),server(ROOT/'dist',8044)]
def check(name,fn):
    try: fn();results.append({'name':name,'pass':True});print('PASS',name,flush=True)
    except Exception as e: results.append({'name':name,'pass':False,'error':str(e)[:700]});raise
def no_overflow(page):
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1')
def click_action(page,action,id=None):
    selector='[data-action="'+action+'"]'+('[data-id="'+id+'"]' if id else '')
    page.locator(selector+':visible').first.click()
def nav(page,id):
    mobile=page.locator('#mobile-nav')
    if mobile.is_visible(): mobile.select_option(id)
    else:click_action(page,'nav',id)
def save_modal(page):
    page.locator('.modal button[type=submit]').click();page.locator('.modal').wait_for(state='detached',timeout=20000)
def login(page,code,password):
    page.locator('#login-form [name=code]').fill(code);page.locator('#login-form [name=password]').fill(password);page.locator('#login-form button[type=submit]').click()
def unlock(page,phrase):
    page.locator('#vault-form').wait_for();page.locator('[name=phrase]').fill(phrase)
    if page.locator('#vault-form [name=repeat]').count():page.locator('#vault-form [name=repeat]').fill(phrase)
    page.locator('#vault-form button[type=submit]').click();page.locator('#vault-form').wait_for(state='detached',timeout=20000);page.locator('#mobile-nav').wait_for(state='attached',timeout=20000)
def assert_true(value):
    assert value
with sync_playwright() as play:
  try:
    for engine in ['chromium','webkit']:
      browser=getattr(play,engine).launch()
      context=browser.new_context(viewport={'width':390,'height':844})
      page=context.new_page();page.goto('http://127.0.0.1:8043/qa-harness.html')
      page.evaluate("async()=>{window.qa=await import('./qa-harness.js');window.qaUser=crypto.randomUUID();window.qaEvent={id:crypto.randomUUID(),captured_at:new Date().toISOString(),outcome:'blank',candidate_id:null};window.qaVault=new qa.Vault('qa-env',qaUser);await qaVault.open();await qaVault.unlock('QA local phrase 2026 safe');await qaVault.add(qaEvent);}")
      check(engine+' writes ciphertext, not plaintext answers',lambda:assert_true(page.evaluate("async()=>{const row=await qaVault.get('entries',qaVault.prefix+'|response:'+qaEvent.id);return !!row.cipher&&!JSON.stringify(row).includes('candidate_id')&&(await qaVault.entries()).length===1;}")))
      check(engine+' wrong phrase never erases records',lambda:assert_true(page.evaluate("async()=>{qaVault.lock();try{await qaVault.unlock('wrong phrase long enough');return false;}catch{await qaVault.unlock('QA local phrase 2026 safe');return (await qaVault.entries()).length===1;}}")))
      check(engine+' another person cannot decrypt prior worker pending data',lambda:assert_true(page.evaluate("async()=>{const other=new qa.Vault('qa-env',crypto.randomUUID());await other.open();await other.unlock('QA another phrase 2026 safe');return (await other.entries()).length===0;}")))
      check(engine+' same UUID retries preserve a single local item',lambda:assert_true(page.evaluate("async()=>{await qaVault.add(qaEvent);try{await qaVault.add({...qaEvent,outcome:'candidate'});return false;}catch{return (await qaVault.entries()).length===1;}}")))
      check(engine+' invalid server receipt cannot clear a pending item',lambda:assert_true(page.evaluate("async()=>{try{await qaVault.acknowledge(qaEvent,{response_id:qaEvent.id});return false;}catch{return (await qaVault.entries())[0].status==='pending';}}")))
      user=page.evaluate('qaUser');event=page.evaluate('qaEvent')
      page.reload();page.evaluate("async({u,e})=>{window.qa=await import('./qa-harness.js');window.qaVault=new qa.Vault('qa-env',u);await qaVault.open();await qaVault.unlock('QA local phrase 2026 safe');window.qaEvent=e;}",{'u':user,'e':event})
      check(engine+' page restart retains encrypted outbox',lambda:assert_true(page.evaluate("async()=>(await qaVault.entries()).length===1")))
      check(engine+' tampered encrypted rescue is rejected without wiping current vault',lambda:assert_true(page.evaluate("async()=>{const r=await qaVault.exportEncrypted();r.entries[0].cipher=r.entries[0].cipher.slice(0,-5)+'AAAAA';try{await qaVault.importEncrypted(r,'QA local phrase 2026 safe');return false;}catch{return (await qaVault.entries()).length===1;}}")))
      b64=base64.b64encode((ROOT/'web/templates/Pulso_R3_Cliente.xlsx').read_bytes()).decode()
      check(engine+' actual R3 Excel parses 12 candidate rows in four cities',lambda:assert_true(page.evaluate("async(b64)=>{const bytes=Uint8Array.from(atob(b64),c=>c.charCodeAt(0));const rows=qa.readXLSX(bytes.buffer,'questionnaires');const data=qa.objectRows(rows,'questionnaires');return data.length===4&&data.reduce((n,c)=>n+c.items.length,0)===12;}",b64)))
      page.goto('http://127.0.0.1:8043/');page.get_by_role('button',name='Administrador',exact=True).wait_for(timeout=90000)
      page.get_by_role('button',name='Administrador',exact=True).click();page.get_by_role('heading',name='Centro de operación').wait_for(timeout=30000)
      for route in ['points','people','tasks','catalog','access','paper','imports','exports','settings','guide','overview']:
        nav(page,route);page.wait_for_timeout(250);check(engine+' admin route '+route,lambda:no_overflow(page))
      page.screenshot(path=str(OUT/(engine+'-admin-mobile.png')),full_page=True)
      click_action(page,'logout');page.get_by_role('button',name='Viewer CDE',exact=True).click();page.get_by_role('heading',name='Acceso a resultados pendiente',exact=True).wait_for(timeout=30000)
      check(engine+' viewer pending state excludes admin controls',lambda:assert_true(page.get_by_text('Acceso a resultados pendiente',exact=True).is_visible() and not page.locator('[data-action="nav"][data-id="access"]').count()))
      click_action(page,'logout');page.get_by_role('button',name='Encuestador CDE',exact=True).click();unlock(page,'QA local phrase demo long')
      click_action(page,'task-start');page.get_by_role('heading',name='Nueva encuesta').wait_for()
      check(engine+' CDE capture only contains own two synthetic candidates',lambda:assert_true(page.locator('.choice[data-outcome=candidate]').count()==2 and 'Ciudad del Este' in page.locator('.taskbar').inner_text()))
      for width in [320,390,430]:
        page.set_viewport_size({'width':width,'height':844});check(engine+f' capture fits {width}px',lambda:no_overflow(page))
      page.set_viewport_size({'width':390,'height':844});page.screenshot(path=str(OUT/(engine+'-capture-mobile.png')),full_page=True)
      page.locator('[name=voted]').check();page.locator('[name=consent]').check();page.locator('.choice[data-outcome=candidate]').first.click();page.locator('#capture-form button[type=submit]').click()
      nav(page,'queue');page.get_by_text('Aceptada',exact=True).wait_for(timeout=20000)
      check(engine+' browser capture obtains SQL server receipt',lambda:assert_true(page.get_by_text('Aceptada',exact=True).is_visible()))
      nav(page,'task');page.on('dialog',lambda dialog:dialog.accept());click_action(page,'finish-my-task');page.get_by_text('Solo envío pendiente',exact=True).first.wait_for(timeout=20000)
      check(engine+' worker finish leaves task drain-only',lambda:assert_true(page.get_by_text('Solo envío pendiente',exact=True).count()>0))
      context.close();browser.close()
    if os.path.exists('/tmp/pulso-v3-browser-private.json'):
      fixture=json.loads(pathlib.Path('/tmp/pulso-v3-browser-private.json').read_text())
      for engine in ['chromium','webkit']:
        browser=getattr(play,engine).launch();adminCtx=browser.new_context(viewport={'width':1440,'height':1000});adminPage=adminCtx.new_page();adminPage.goto('http://127.0.0.1:8044/')
        login(adminPage,fixture['admin']['code'],fixture['admin']['password']);adminPage.get_by_role('heading',name='Centro de operación').wait_for(timeout=30000)
        nav(adminPage,'tasks');click_action(adminPage,'task-new');adminPage.locator('.modal [name=person_id]').select_option(fixture['person']);adminPage.locator('.modal [name=point_id]').select_option(fixture['point']);adminPage.locator('.modal [name=reason]').fill('QA browser native task '+engine);save_modal(adminPage)
        workerCtx=browser.new_context(viewport={'width':390,'height':844});p=workerCtx.new_page();p.goto('http://127.0.0.1:8044/');login(p,fixture['worker']['code'],fixture['worker']['password']);unlock(p,'QA native device phrase 2026')
        click_action(p,'task-ack');p.locator('[data-action=task-start]').wait_for(timeout=20000);click_action(p,'task-start');p.get_by_role('heading',name='Nueva encuesta').wait_for()
        p.locator('[name=voted]').check();p.locator('[name=consent]').check();p.locator('.choice[data-outcome=candidate]').first.click();p.locator('#capture-form button[type=submit]').click();nav(p,'queue');p.get_by_text('Aceptada',exact=True).wait_for(timeout=20000)
        check(engine+' native UI write reaches actual Supabase receipt',lambda:assert_true(p.get_by_text('Aceptada',exact=True).is_visible()))
        nav(p,'task');p.on('dialog',lambda dialog:dialog.accept());click_action(p,'finish-my-task');p.get_by_text('Solo envío pendiente',exact=True).first.wait_for(timeout=20000)
        nav(adminPage,'overview');click_action(adminPage,'refresh');adminPage.screenshot(path=str(OUT/(engine+'-native-admin.png')),full_page=True)
        check(engine+' native worker task completion',lambda:assert_true(p.get_by_text('Solo envío pendiente',exact=True).count()>0))
        workerCtx.close();adminCtx.close();browser.close()
  except Exception as e:
    print('BROWSER FAILURE',str(e)[:800],flush=True)
    if not results or results[-1]['pass']:results.append({'name':'Browser flow execution','pass':False,'error':str(e)[:700]})
    with contextlib.suppress(Exception):page.screenshot(path=str(OUT/'failure.png'),full_page=True)
  finally:
    (ROOT/'evidence/browser.json').write_text(json.dumps({'environment':'CI Chromium/WebKit; SQL simulation, encrypted browser storage; optional actual local Supabase browser flow; not real iPhone','at':time.time(),'passed':sum(r['pass'] for r in results),'failed':sum(not r['pass'] for r in results),'results':results},ensure_ascii=False,indent=2))
    for s in servers:s.shutdown()
if not results or any(not r['pass'] for r in results):raise SystemExit(1)
