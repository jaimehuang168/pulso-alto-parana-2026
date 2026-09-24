"""Source-only release review patches. No hosted Supabase or user data access."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'v3/tests/native.mjs';s=p.read_text()
s=s.replace('new pg.Client({connectionString:dbUrl})','new pg.Client({connectionString:dbUrl,statement_timeout:20000,query_timeout:25000})')
old="const check=async(name,f)=>{try{await f();results.push({name,pass:true});console.log('PASS',name);}catch(e){results.push({name,pass:false,error:String(e.message||e).slice(0,400)});throw e;}};"
new="const check=async(name,f)=>{console.log('BEGIN',name);try{await f();results.push({name,pass:true});console.log('PASS',name);}catch(e){results.push({name,pass:false,error:String(e.message||e).slice(0,400)});throw e;}finally{await fs.writeFile(new URL('native-progress.json',evidence),JSON.stringify({completed:false,results},null,2));}};"
if old in s:s=s.replace(old,new)
# Independent tests continue after a failed event-delivery assertion. The final verdict remains failed.
s=s.replace("()=>verifyRealtime({admin,worker,service,db,event,rpc,evidence}));","()=>verifyRealtime({admin,worker,service,db,event,rpc,evidence})).catch(()=>{});")
s=s.replace('await Promise.all([admin,worker,coord,viewerSession].filter(Boolean).map(c=>c.removeAllChannels().catch(()=>{})));await db.end();}',"await Promise.all([admin,worker,coord,viewerSession,service].filter(Boolean).map(async c=>{await c.removeAllChannels().catch(()=>{});await c.realtime.disconnect();}));await db.end();}\nif(results.some(r=>!r.pass))process.exitCode=1;\nprocess.exit(process.exitCode||0);")
p.write_text(s)
p=R/'v3/web/app.mjs';s=p.read_text()
s=s.replace("const rows=await vault.entries();for(const row of rows.filter(x=>x.status!=='received'&&(manual||!x.blocked))){","const rows=await vault.entries(),attempted=rows.filter(x=>x.status!=='received'&&(manual||!x.blocked));for(const row of attempted){")
s=s.replace("toast(S.queue.some(x=>x.status!=='received')?'Revise los pendientes sin confirmar.':'Todos los registros locales tienen recibo.');", "if(manual||attempted.length)toast(S.queue.some(x=>x.status!=='received')?'Revise los pendientes sin confirmar.':'Todos los registros locales tienen recibo.');")
s=s.replace("document.getElementById('selection-summary').textContent=S.choice.label;break;", "document.getElementById('selection-summary').textContent=S.choice.label;document.querySelector('.capture-actions')?.classList.add('ready');break;")
s=s.replace("C.download(C.csv([['CODE','PASSWORD'],[S.credential.code,S.credential.password]]),'PULSO_CREDENCIAL_PRIVADA_NO_PUBLICAR.csv','text/csv')", "C.download(C.credentialText(S.credential),'PULSO_CREDENCIAL_PRIVADA_NO_PUBLICAR.txt','text/plain;charset=utf-8')")
p.write_text(s)
p=R/'v3/web/modules/views.mjs';s=p.read_text().replace('<div class="capture-actions">', '<div class="capture-actions${S.choice?\' ready\':\'\'}">');p.write_text(s)
p=R/'v3/web/styles.css';s=p.read_text()
if '.capture-actions:not(.ready)' not in s:s+='\n.capture-actions:not(.ready){position:static;box-shadow:none}.capture-actions.ready{position:sticky;bottom:max(12px,env(safe-area-inset-bottom))}\n'
p.write_text(s)
p=R/'v3/web/modules/core.mjs';s=p.read_text()
if 'export function credentialText' not in s:s+='\n/** Private TXT avoids spreadsheet coercion of a leading minus in a generated password. */\nexport function credentialText(c){if(!c||typeof c.code!=="string"||typeof c.password!=="string"||/[\\r\\n]/.test(c.code+c.password))throw new Error("V3_INVALID_CREDENTIAL");return "PULSO · CREDENCIAL PRIVADA\\nCódigo: "+c.code+"\\nContraseña: "+c.password+"\\nNo publicar ni compartir con otras personas.\\n";}\n'
p.write_text(s)
print('Deterministic test completion and operator-facing edge cases prepared.')
