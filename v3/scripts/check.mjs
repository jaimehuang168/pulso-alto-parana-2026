import fs from 'node:fs/promises';import path from 'node:path';import {spawnSync} from 'node:child_process';
const root=new URL('../',import.meta.url),files=[];
async function walk(dir){for(const e of await fs.readdir(dir,{withFileTypes:true})){if(['node_modules','dist','preview','evidence'].includes(e.name))continue;const p=path.join(dir,e.name);if(e.isDirectory())await walk(p);else files.push(p);}}
await walk(root.pathname);let errors=[];
for(const f of files.filter(x=>x.endsWith('.mjs'))){const r=spawnSync(process.execPath,['--check',f],{encoding:'utf8'});if(r.status)errors.push(f+': '+r.stderr);}
const migrations=path.join(root.pathname,'../supabase/migrations');for(const f of (await fs.readdir(migrations)).filter(x=>/^00[4-8]/.test(x))){let s=await fs.readFile(path.join(migrations,f),'utf8');if(/safeupdate\.enabled\s*=\s*off|disable\s+row\s+level\s+security|where\s+true\b/i.test(s))errors.push(f+': unsafe protection bypass');}
if(errors.length){console.error(errors.join('\n'));process.exit(1);}console.log('JavaScript syntax and database protection lint passed. Not a substitute for runtime tests.');
