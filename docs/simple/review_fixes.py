"""Apply reviewed source changes once. No connection to any database or cloud."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'supabase/migrations/015_v3_simple_interviewers.sql';s=p.read_text()
s=s.replace("AND contype='c' AND pg_get_constraintdef(oid) LIKE '%training_passed_at%'", "AND contype='c' AND conname='people_check' AND pg_get_constraintdef(oid) LIKE '%training_passed_at%' AND pg_get_constraintdef(oid) LIKE '%training_practice_ack%'")
insert="""
-- Restore managed workers through the existing revision-checked, audited admin command.
-- Retain every other operation and the external-report wrapper unchanged.
DO $managed_restore$
DECLARE definition text; old_check text:='IF per.training_passed_at IS NULL OR NOT per.training_practice_ack OR length(reason)<5 THEN';
 new_check text:='IF (per.onboarding_mode<>''admin_managed'' AND (per.training_passed_at IS NULL OR NOT per.training_practice_ack)) OR length(reason)<5 OR (per.onboarding_mode=''admin_managed'' AND a.role<>''admin'') THEN';
BEGIN
 SELECT pg_get_functiondef('pulso_v3.command_before_reports(text,jsonb,uuid,bigint,integer)'::regprocedure) INTO definition;
 IF strpos(definition,old_check)>0 THEN
  IF length(definition)-length(replace(definition,old_check,''))<>length(old_check) THEN RAISE EXCEPTION 'V3_SIMPLE_COMMAND_LAYOUT';END IF;
  EXECUTE replace(definition,old_check,new_check);
 ELSIF strpos(definition,new_check)=0 THEN RAISE EXCEPTION 'V3_SIMPLE_COMMAND_LAYOUT';END IF;
END $managed_restore$;
REVOKE ALL ON FUNCTION public.v3_start_task(uuid,uuid,integer) FROM PUBLIC,anon;
"""
assert 'DO $managed_restore$' not in s
s=s.replace('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pulso_v3',insert+'\nREVOKE ALL ON ALL FUNCTIONS IN SCHEMA pulso_v3');p.write_text(s)
for name in ['workspace-base.mjs','views.mjs']:
 p=R/'v3/web/modules'/name;s=p.read_text().replace("p.approval==='pending'&&p.training_passed_at?", "p.approval==='pending'&&(p.training_passed_at||p.onboarding_mode==='admin_managed'&&S.boot.actor.role==='admin')?")
 s=s.replace('Cuenta habilitada por administración','Cuenta individual de la empresa')
 if name=='views.mjs':
  assert 'export function pageView(S){' in s
  s=s.replace('export function pageView(S){','export function pageView(S){\n if(S.page===\'guide\'&&S.simple)return \'<section class="card"><h1>Ayuda para su teléfono</h1><p>Use el código y la contraseña que recibió. La tarea y el almacenamiento se preparan automáticamente.</p><a class="button primary" href="manual-simple.html" target="_blank" rel="noopener">Ver guía actualizada paso a paso</a><p>Si necesita ayuda, informe su código, ciudad y el mensaje de error. No comparta contraseñas ni borre datos.</p></section>\';')
 p.write_text(s)
p=R/'v3/tests/simple-sql.mjs';s=p.read_text();target=" await check('No false activation or synthetic vote inserted'"
more=""" await check('Managed worker can be restored and approved by admin without inventing practice',async()=>{
  let rev=(await db.query('select revision from pulso_v3.people where id=$1',[person])).rows[0].revision;
  await rpc('v3_command',['person.restore',{id:person,reason:'Restauración revisada por administración de ensayo'},uuid(),rev]);
  rev=(await db.query('select revision from pulso_v3.people where id=$1',[person])).rows[0].revision;
  await rpc('v3_command',['person.approve',{id:person,reason:'Rehabilitación de la misma persona por administración'},uuid(),rev]);
  const row=(await db.query('select approval,training_passed_at,training_practice_ack from pulso_v3.people where id=$1',[person])).rows[0];
  assert.equal(row.approval,'approved');assert.equal(row.training_passed_at,null);assert.equal(row.training_practice_ack,false);
 });
"""
assert target in s;s=s.replace(target,more+target);p.write_text(s)
p=R/'v3/tests/simple-browser.py';s=p.read_text().replace('import json,threading,http.server,functools,uuid,urllib.request,time','import json,threading,http.server,functools,uuid,urllib.request,time,socket')
s=s.replace('class Quiet(http.server.SimpleHTTPRequestHandler):',"NETWORK_CUT=threading.Event()\nblocked_static=[]\nclass Quiet(http.server.SimpleHTTPRequestHandler):\n def do_GET(self):\n  if NETWORK_CUT.is_set():\n   blocked_static.append(self.path)\n   try:self.connection.shutdown(socket.SHUT_RDWR)\n   except OSError:pass\n   self.connection.close();return\n  super().do_GET()")
s=s.replace("def snap(p,n):p.screenshot(path=str(OUT/n),full_page=True)","""def snap(p,n):p.screenshot(path=str(OUT/n),full_page=True)
def offline(ctx,p,enabled,engine):
 if engine=='chromium':ctx.set_offline(enabled);return
 # Playwright issue 42775: WebKit setOffline rejects even literal SW responses.
 # Disconnect the real static server and all API traffic; emulate only the indicator.
 # No cached HTML or responses are supplied by this test.
 if enabled:
  NETWORK_CUT.set();ctx.route(F['url']+'/**',lambda r:r.abort())
  ctx.add_init_script("Object.defineProperty(Navigator.prototype,'onLine',{configurable:true,get(){return localStorage.getItem('__qa_network_cut')!=='yes'}})")
  p.evaluate("localStorage.setItem('__qa_network_cut','yes');Object.defineProperty(Navigator.prototype,'onLine',{configurable:true,get(){return localStorage.getItem('__qa_network_cut')!=='yes'}});dispatchEvent(new Event('offline'))")
 else:
  NETWORK_CUT.clear();ctx.unroute(F['url']+'/**');p.evaluate("localStorage.removeItem('__qa_network_cut');dispatchEvent(new Event('online'))")
""")
s=s.replace('mobile.set_offline(True);','offline(mobile,p,True,engine);').replace('mobile.set_offline(False);','offline(mobile,p,False,engine);')
old="   p.reload();p.locator('#capture-form').wait_for(timeout=30000);idle(p);go(p,'queue');check(engine+' offline page reload retains own pending records',p.locator('#vault-form').count()==0 and 'Sin confirmar' in p.locator('body').inner_text())"
assert old in s;s=s.replace(old,"""   check(engine+' installed static shell controls the page',p.evaluate('!!navigator.serviceWorker.controller'))
   p.reload();p.locator('#capture-form').wait_for(timeout=30000);idle(p);go(p,'queue');check(engine+' offline page reload retains own pending records',p.locator('#vault-form').count()==0 and 'Sin confirmar' in p.locator('body').inner_text())
   if engine=='webkit':check('WebKit restored cached shell while real static network requests were disconnected',len(blocked_static)>0 and not p.evaluate('navigator.onLine'))""")
s=s.replace("'scope':'Real Chromium/WebKit, local Auth and Edge, synthetic responses. Not physical devices or production.'","'scope':'Real Chromium/WebKit and local Auth/Edge. Chromium native offline emulation; WebKit static-server disconnect + API abort + explicit offline indicator, due to Playwright issue 42775. Not physical devices or production.'")
s=s.replace('finally:\n srv.shutdown();', 'finally:\n NETWORK_CUT.clear();srv.shutdown();');p.write_text(s)
print('Reviewed source changes applied; production untouched.')
