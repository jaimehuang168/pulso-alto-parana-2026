/* Static shell only. Never cache Auth, API responses or staff GPS in CacheStorage. */
const CACHE='pulso-shell-v2.0.0';
const SHELL=['./','./index.html','./styles.css','./core.js','./app.js','./config.js','./supabase-vendor.js','./icon.svg','./icon-192.png','./icon-512.png','./manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL))));
// A waiting update activates after the user closes existing tabs; never force-reload a survey.
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('pulso-shell-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{
 const req=event.request,url=new URL(req.url);
 if(req.method!=='GET'||url.origin!==self.location.origin)return;
 const allowed=SHELL.some(p=>new URL(p,self.registration.scope).pathname===url.pathname);
 if(!allowed)return;
 event.respondWith(fetch(req).then(res=>{if(res.ok)event.waitUntil(caches.open(CACHE).then(cache=>cache.put(req,res.clone())));return res;}).catch(async()=>await caches.match(req)||new Response('Sin conexión. Abra la aplicación en línea al menos una vez.',{status:503})));
});
