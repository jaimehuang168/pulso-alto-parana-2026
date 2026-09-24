"""Tighten native test diagnostics; never connects to production."""
from pathlib import Path
p=Path('v3/tests/native.mjs');s=p.read_text()
old="await check('Realtime delivers a scoped revision notification after a confirmed write',async()=>{let delivered=false;"
new="await check('Realtime delivers a scoped revision notification after a confirmed write',async()=>{const permitted=await admin.from('v3_signals').select('district_id,revision');if(permitted.error)throw Object.assign(new Error(permitted.error.message),permitted.error);assert.equal(permitted.data.length,4,'Admin must pass signal RLS with real JWT before subscription');await admin.realtime.setAuth((await admin.auth.getSession()).data.session.access_token);let delivered=false;"
if old in s:
 assert s.count(old)==1
 s=s.replace(old,new)
old="console.error('Native test failed:',e.message||e);process.exitCode=1;"
new="""console.error('Native test failed:',e.message||e);process.exitCode=1;
 try{const facts=await db.query("select exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='v3_signals') publication_ok,has_function_privilege('authenticated','public.v3_can_read_signal(text)','execute') signal_function_grant,has_table_privilege('authenticated','public.v3_signals','select') signal_table_grant");await fs.writeFile(new URL('native-diagnostic.json',evidence),JSON.stringify({facts:facts.rows,scope:'Boolean permissions only; no tokens or answers'}));}catch{}
"""
if 'native-diagnostic.json' not in s:
 assert old in s
 s=s.replace(old,new)
if 'removeAllChannels' not in s:
 assert 'await db.end();}' in s
 s=s.replace('await db.end();}',"await Promise.all([admin,worker,coord,viewerSession].filter(Boolean).map(c=>c.removeAllChannels().catch(()=>{})));await db.end();}")
p.write_text(s)
print('Native Realtime assertions and cleanup prepared.')
