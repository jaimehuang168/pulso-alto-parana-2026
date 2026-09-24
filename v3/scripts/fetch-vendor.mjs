import fs from 'node:fs/promises';import {createHash} from 'node:crypto';
const url='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.116.0/dist/umd/supabase.js';
const r=await fetch(url,{signal:AbortSignal.timeout(30000)});if(!r.ok)throw Error('Pinned SDK download failed');const bytes=Buffer.from(await r.arrayBuffer());
const expected='84ee9bf45695c1dd3ba1595b6bcfb0f09672434631351ffc8ebe9140545d5ff6';if(createHash('sha256').update(bytes).digest('hex')!==expected)throw Error('Pinned SDK hash mismatch; do not publish');
await fs.writeFile(new URL('../../web/supabase-vendor.js',import.meta.url),bytes);console.log('Pinned public SDK verified. No credentials written.');
