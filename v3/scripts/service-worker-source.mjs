/** Generate a scope-isolated static shell worker. No Auth/API data is cached. */
export function serviceWorkerSource(release,files){
 if(!/^[a-z0-9-]{5,100}$/i.test(release)||!Array.isArray(files)||files.some(f=>typeof f!=='string'||!/^[a-zA-Z0-9_.-]+$/.test(f)||f.includes('..')))throw new Error('V3_INVALID_SHELL_MANIFEST');
 const shell=['./',...files.map(f=>'./'+f),'./vendor/supabase.js'];
 return `/* Static assets only; each registration scope owns its own release caches. */
const PREFIX='pulso-v3:'+self.registration.scope+':';
const CACHE=PREFIX+${JSON.stringify(release)},SHELL=${JSON.stringify(shell)};
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL))));
// Never reload a working survey and never delete V2 or a sibling V3 site's cache.
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith(PREFIX)&&key!==CACHE).map(key=>caches.delete(key))))));
self.addEventListener('fetch',event=>{
 const request=event.request,url=new URL(request.url);
 if(request.method!=='GET'||url.origin!==self.location.origin||!SHELL.some(p=>new URL(p,self.registration.scope).pathname===url.pathname))return;
 event.respondWith(fetch(request).then(response=>{if(response.ok)event.waitUntil(caches.open(CACHE).then(cache=>cache.put(request,response.clone())));return response;}).catch(()=>caches.match(request).then(cached=>cached||new Response('Sin conexión; conecte el dispositivo para instalar la versión.',{status:503}))));
});
`;
}
