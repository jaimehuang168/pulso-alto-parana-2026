"""Prepare release source only; never opens a connection or performs a restore."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'v3/scripts/build.mjs';s=p.read_text()
if "import {serviceWorkerSource}" not in s:
 s="import {serviceWorkerSource} from './service-worker-source.mjs';\n"+s
 lines=s.splitlines(keepends=True);matches=[i for i,line in enumerate(lines) if line.startswith("await fs.writeFile(path.join(out,'sw.js'),")]
 assert len(matches)==1
 lines[matches[0]]="await fs.writeFile(path.join(out,'sw.js'),serviceWorkerSource(cache,files));\n"
 s=''.join(lines);p.write_text(s)
p=R/'v3/tests/restore-native.mjs';s=p.read_text()
s=s.replace("['pg_restore','-U','postgres','-d',name,'--exit-on-error'", "['pg_restore','-U','postgres','-d',name,'--clean','--if-exists','--exit-on-error'")
s=s.replace("throw new Error('Local backup/restore command failed: '+args[0]+' (exit '+e.status+')');", "const reason=String(e.stderr||'').split('\\n').filter(line=>/ERROR:|FATAL:/.test(line)).map(line=>line.replace(/\\S+@\\S+/g,'[redacted]').replace(/[A-Za-z0-9_=-]{45,}/g,'[redacted]')).slice(0,3).join(' | ').slice(0,500);throw new Error('Local backup/restore command failed: '+args[0]+' (exit '+e.status+'): '+reason);")
p.write_text(s)
p=R/'v3/tests/native.mjs';s=p.read_text()
old="for(const f of ['004_v3_expand.sql','005_v3_api.sql','006_v3_enrollment.sql','007_v3_cutover.sql','008_v3_storage.sql'])await db.query(await fs.readFile(new URL('../../supabase/migrations/'+f,import.meta.url),'utf8'));"
new="await db.query(await fs.readFile(new URL('../../supabase/V3_UPGRADE_EXISTING.sql',import.meta.url),'utf8'));"
if old in s:
 assert s.count(old)==1;s=s.replace(old,new)
else:assert new in s
p.write_text(s)
print('Release build and disposable restore source prepared. No database was modified by this script.')
