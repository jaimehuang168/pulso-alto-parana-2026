"""Reviewed usability corrections and local integration diagnostics; no remote database."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'v3/web/app.mjs';s=p.read_text()
if 'function setBusy' not in s:
 s=s.replace("function render(){document.getElementById('app').innerHTML", "function setBusy(value){S.busy=value;document.getElementById('app').setAttribute('aria-busy',String(value));}\nfunction render(){document.getElementById('app').setAttribute('aria-busy',String(S.busy));document.getElementById('app').innerHTML",1)
 s=s.replace('S.busy=true;','setBusy(true);').replace('S.busy=false;','setBusy(false);')
 s=s.replace("if(e.target.id==='mobile-nav')navigate(e.target.value).catch(error);", "if(e.target.id==='mobile-nav'){if(S.busy){e.target.value=S.page;toast('Espere a que termine la operación antes de cambiar de pantalla.');}else navigate(e.target.value).catch(error);}")
 s=s.replace("d[k]=typeof v==='string'?v.trim():v;", "d[k]=typeof v==='string'?(form.elements.namedItem(k)?.type==='password'?v:v.trim()):v;")
 s=s.replace("case 'paper-form':data.response_id=C.uuid();", "case 'paper-form':data.response_id=formEl.dataset.responseId||(formEl.dataset.responseId=C.uuid());")
 s=s.replace("formEl.reset();delete formEl.dataset.request;break;", "formEl.reset();delete formEl.dataset.request;delete formEl.dataset.responseId;break;")
 p.write_text(s)
p=R/'v3/tests/browser.py';s=p.read_text()
if 'aria-busy' not in s:
 s=s.replace('def click_action(page,action,id=None):', 'def click_action(page,action,id=None):\n    page.wait_for_function("document.querySelector(\'#app\')?.getAttribute(\'aria-busy\') !== \'true\'")')
 s=s.replace('def nav(page,id):','def nav(page,id):\n    page.wait_for_function("document.querySelector(\'#app\')?.getAttribute(\'aria-busy\') !== \'true\'")')
 p.write_text(s)
p=R/'v3/tests/native.mjs';s=p.read_text()
old="await admin.removeChannel(ch);assert(delivered,'Must observe an event, not just SUBSCRIBED');"
new="""const diagnostic=await db.query("select count(*) subscriptions,count(*) filter(where claims ? 'session_id') sessions_in_claims,count(*) filter(where claims->>'role'='authenticated') authenticated_subscriptions,count(*) filter(where exists(select 1 from auth.sessions a where a.id::text=claims->>'session_id' and a.user_id::text=claims->>'sub')) existing_sessions from realtime.subscription where entity='public.v3_signals'::regclass");await fs.writeFile(new URL('native-realtime-route.json',evidence),JSON.stringify({subscription_counts:diagnostic.rows,received:delivered,scope:'Aggregate counts only; no JWT, names, or answers'}));await admin.removeChannel(ch);assert(delivered,'Must observe an event, not just SUBSCRIBED');"""
if old in s:
 assert s.count(old)==1;s=s.replace(old,new)
 p.write_text(s)
print('UI race conditions and local-only aggregate diagnostics prepared.')
