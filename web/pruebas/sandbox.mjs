import {validateConfig} from './core.mjs';
export const TARGET_KEY='pulso-existing-test-project-1';
export function sandboxConfig(target,production){
 const p=validateConfig(production),t=validateConfig(target);
 if(t.url===p.url)throw Error('PRODUCTION_TARGET_FORBIDDEN');
 return {supabaseUrl:t.url,publishableKey:t.key,environment:'EXISTING_TEST_PROJECT_ONLY',simulation:false,build:'pruebas-1'};
}
export async function productionConfig(fetcher=fetch){
 const r=await fetcher(new URL('../v3/config.js',import.meta.url),{cache:'no-store',signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('PRODUCTION_CONFIG_UNAVAILABLE');
 const text=await r.text(),m=text.match(/^window\.PULSO_V3_CONFIG=(\{.*\});?\s*$/s);if(!m)throw Error('PRODUCTION_CONFIG_INVALID');const c=JSON.parse(m[1]);validateConfig(c);return c;
}
export function packTarget(c){validateConfig(c);return btoa(unescape(encodeURIComponent(JSON.stringify({supabaseUrl:c.supabaseUrl,publishableKey:c.publishableKey,simulation:false}))));}
export function unpackTarget(x){if(typeof x!=='string'||x.length>4000)throw Error('CONFIG_INVALID');const c=JSON.parse(decodeURIComponent(escape(atob(x))));validateConfig(c);return c;}
