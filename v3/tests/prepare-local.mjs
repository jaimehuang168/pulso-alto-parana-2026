/** Only for a disposable Supabase CLI instance. Does not accept a remote URL. */
import fs from 'node:fs/promises';import path from 'node:path';
const root=process.argv[2];if(!root?.startsWith('/tmp/pulso-v3-'))throw Error('Disposable /tmp workspace required');
const configPath=path.join(root,'supabase/config.toml');let cfg=await fs.readFile(configPath,'utf8');
cfg=cfg.replace(/^project_id\s*=.*$/m,'project_id = "pulso-v3-ci"');
// CI load fixture only: this is not a request to alter production Auth limits.
cfg=cfg.replace(/^sign_in_sign_ups\s*=.*$/m,'sign_in_sign_ups = 1000');
cfg=cfg.replace(/^site_url\s*=.*$/m,'site_url = "http://127.0.0.1:8044"');
cfg+='\n[functions.field-enrollment]\nverify_jwt = false\n';
await fs.writeFile(configPath,cfg);await fs.mkdir(path.join(root,'supabase/functions/field-enrollment'),{recursive:true});
await fs.copyFile(new URL('../../supabase/functions/field-enrollment/index.ts',import.meta.url),path.join(root,'supabase/functions/field-enrollment/index.ts'));
