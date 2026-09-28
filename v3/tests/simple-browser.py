"""Own-phone creation/login/storage/offline tests against real disposable Supabase."""
from pathlib import Path
import json,threading,http.server,functools,uuid,urllib.request,time
from playwright.sync_api import sync_playwright
R=Path(__file__).resolve().parents[2];F=json.loads(Path('/tmp/pulso-simple-private.json').read_text());OUT=R/'v3/evidence/simple-browser';OUT.mkdir(parents=True,exist_ok=True);checks=[]
assert F['url'].startswith('http://127.0.0.1:')
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',8044),functools.partial(Quiet,directory=str(R/'web')));threading.Thread(target=srv.serve_forever,daemon=True).start()
BASE='http://127.0.0.1:8044'
def check(n,v):
 checks.append({'name':n,'pass':bool(v)});print('PASS' if v else 'FAIL',n,flush=True);assert v,n
def idle(p):p.wait_for_function("document.querySelector('#app')?.getAttribute('aria-busy')!=='true'",timeout=30000)
def login(p,c):
 p.goto(BASE+'/v3/');f=p.locator('#login-form');f.wait_for(timeout=30000);f.locator('[name=code]').fill(c['code']);f.locator('[name=password]').fill(c['password']);f.locator('button[type=submit]').click()
def go(p,name):idle(p);p.locator('[data-action=nav][data-id='+name+']:visible').first.click();idle(p)
def snap(p,n):p.screenshot(path=str(OUT/n),full_page=True)
try:
 with sync_playwright() as w:
  for engine in ['chromium','webkit']:
   browser=getattr(w,engine).launch();a=browser.new_page(viewport={'width':1440,'height':1000},locale='es-PY');login(a,F['admin']);a.get_by_role('heading',name='Resultados',exact=True).wait_for(timeout=30000);go(a,'people')
   a.get_by_role('button',name='Crear encuestador',exact=True).click();form=a.locator('#simple-account-form');form.wait_for()
   cred={'code':'ENC-BROWSER-'+('CHR' if engine=='chromium' else 'WEB'),'password':'BrowserOwnPhone-Only2026!'}
   form.locator('[name=display_name]').fill('María de prueba '+engine);form.locator('[name=code]').fill(cred['code']);form.locator('[name=password]').fill(cred['password'])
   form.locator('#simple-city').select_option('cde');form.locator('#simple-station').select_option(F['fixtures'][0]['station']);form.locator('#simple-point').select_option(F['fixtures'][0]['point'])
   check(engine+' creation form filters points by chosen city',form.locator('#simple-point option').count()==2)
   snap(a,engine+'-admin-create.png');form.locator('button[type=submit]').click();a.get_by_role('heading',name='Credenciales privadas',exact=True).wait_for(timeout=30000)
   check(engine+' actual admin creation returns chosen personal code',cred['code'] in a.locator('.credential').inner_text())
   a.locator('[data-action=close-modal]:visible').first.click();a.reload();a.get_by_role('heading',name='Resultados',exact=True).wait_for();go(a,'people');check(engine+' created worker visible without fabricated practice','María de prueba '+engine in a.locator('body').inner_text());snap(a,engine+'-team.png')
   mobile=browser.new_context(viewport={'width':390,'height':844},locale='es-PY',has_touch=True);p=mobile.new_page();login(p,cred)
   p.locator('#capture-form').wait_for(timeout=30000);idle(p)
   check(engine+' one login goes directly to assigned questionnaire',p.locator('#vault-form').count()==0 and p.locator('[data-action=task-ack]').count()==0 and p.locator('[data-action=task-start]').count()==0)
   check(engine+' current person is visible',p.locator('[data-session-name]').inner_text()=='María de prueba '+engine)
   check(engine+' only assigned city choices shown',p.locator('.choice[data-outcome=candidate]').count()==2 and all('cde' in s for s in p.locator('.choice[data-outcome=candidate]').all_text_contents()))
   check(engine+' mobile form has no horizontal overflow',p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   snap(p,engine+'-ready.png')
   p.locator('[name=voted]').check();p.locator('[name=consent]').check();p.locator('.choice[data-outcome=candidate]').first.click();snap(p,engine+'-choice.png');p.locator('#capture-form button[type=submit]').click();idle(p);go(p,'queue');p.get_by_text('Aceptada',exact=True).wait_for(timeout=30000)
   check(engine+' no-GPS survey gets accepted through real server',p.get_by_text('Aceptada',exact=True).count()==1);snap(p,engine+'-receipt.png')
   # A normal reload requires no second passphrase and installs the static shell.
   p.evaluate('navigator.serviceWorker.ready.then(()=>true)');p.reload();p.locator('#capture-form').wait_for(timeout=30000);idle(p)
   check(engine+' reloading reopens same personal archive automatically',p.locator('#vault-form').count()==0)
   mobile.set_offline(True);p.locator('[name=voted]').check();p.locator('[name=consent]').check();p.locator('.choice[data-outcome=candidate]').nth(1).click();p.locator('#capture-form button[type=submit]').click();idle(p);go(p,'queue')
   check(engine+' offline survey stays in encrypted queue',p.locator('body').inner_text().count('Sin confirmar')>=1);snap(p,engine+'-offline.png')
   p.reload();p.locator('#capture-form').wait_for(timeout=30000);idle(p);go(p,'queue');check(engine+' offline page reload retains own pending records',p.locator('#vault-form').count()==0 and 'Sin confirmar' in p.locator('body').inner_text())
   mobile.set_offline(False);p.get_by_text('Aceptada',exact=True).nth(1).wait_for(timeout=45000)
   check(engine+' reconnection automatically syncs the original pending record',p.get_by_text('Aceptada',exact=True).count()==2)
   p.locator('[data-action=sync]:visible').click();idle(p);check(engine+' repeated sync does not duplicate accepted records',p.get_by_text('Aceptada',exact=True).count()==2);snap(p,engine+'-synced.png')
   p.locator('[data-action=logout]:visible').first.click();p.locator('#login-form').wait_for(timeout=20000)
   check(engine+' logout removes personal offline authorization',p.evaluate('localStorage.getItem("pulso-personal-current")') is None and p.locator('[data-session-identity]').count()==0)
   login(p,cred);p.locator('#capture-form').wait_for(timeout=30000);check(engine+' same phone signs back in without manual task renewal',p.locator('#vault-form').count()==0)
   # Exercise real CryptoKey persistence and legacy-copy recovery with isolated synthetic data only.
   result=p.evaluate('''async()=>{
    const {DeviceVault}=await import('/qa-src/device-vault.mjs');const{Vault}=await import('/qa-src/vault.mjs');
    const user=crypto.randomUUID(),env='isolated-browser-crypto',phrase='Legacy test phrase 2026';
    const old=new Vault(env,user);await old.open();await old.unlock(phrase);const event={id:crypto.randomUUID(),captured_at:new Date().toISOString(),test:'synthetic'};await old.add(event);const original=JSON.stringify(await old.exportEncrypted());old.lock();
    const v=new DeviceVault(env,user);await v.open();const needsLegacy=!(await v.automaticUnlock(true));let wrongRejected=false;
    try{await v.migrateLegacy('wrong legacy phrase 2026')}catch{wrongRejected=true}
    await v.migrateLegacy(phrase);const matches=JSON.stringify((await v.entries())[0].event)===JSON.stringify(event);const auto=new DeviceVault(env,user);await auto.open();const automatic=await auto.automaticUnlock(false);
    let exportBlocked=false;try{await crypto.subtle.exportKey('raw',auto.key)}catch{exportBlocked=true}
    const backup=await auto.portableBackup();const sameIdentity=new DeviceVault(env,user);await sameIdentity.open();await sameIdentity.automaticUnlock(false);await sameIdentity.importEncrypted(backup.data,backup.phrase);
    const other=new DeviceVault(env,crypto.randomUUID());await other.open();await other.automaticUnlock(true);let foreignRejected=false;try{await other.importEncrypted(backup.data,backup.phrase)}catch{foreignRejected=true}
    const sourceUnchanged=JSON.stringify(await old.exportEncrypted())===original;
    // Ignore export creation timestamp only; compare exact keys and entry bytes.
    const before=JSON.parse(original),after=await old.exportEncrypted();const preserved=JSON.stringify(before.key)===JSON.stringify(after.key)&&JSON.stringify(before.entries)===JSON.stringify(after.entries);
    return{needsLegacy,wrongRejected,matches,automatic,exportBlocked,foreignRejected,preserved,ownCount:(await sameIdentity.entries()).length};
   }''')
   for k in ['needsLegacy','wrongRejected','matches','automatic','exportBlocked','foreignRejected','preserved']:check(engine+' encryption / recovery '+k,result[k])
   check(engine+' backup roundtrip retains one event',result['ownCount']==1)
   mobile.close();a.close();browser.close()
except Exception as e:
 text=str(e)
 for c in [F['admin'],F['root'],F['viewer']]:text=text.replace(c['password'],'[redacted]')
 checks.append({'name':'Browser execution','pass':False,'error':text[:800]})
finally:
 srv.shutdown();d={'scope':'Real Chromium/WebKit, local Auth and Edge, synthetic responses. Not physical devices or production.','passed':sum(c['pass'] for c in checks),'failed':sum(not c['pass'] for c in checks),'checks':checks};(R/'v3/evidence/simple-browser.json').write_text(json.dumps(d,indent=2));print(json.dumps(d,indent=2))
 if d['failed']:raise SystemExit(1)
