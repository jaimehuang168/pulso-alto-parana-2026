/** Build live monitor and an explicitly synthetic standalone demonstration. */
import {build} from 'esbuild';import fs from 'node:fs/promises';import path from 'node:path';import {fileURLToPath} from 'node:url';
const source=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(source,'../..');
for(const demo of[false,true]){
 const out=path.join(root,'web',demo?'live-demo':'live');await fs.mkdir(out,{recursive:true});
 await build({entryPoints:[path.join(source,'app.mjs')],outfile:path.join(out,'live.js'),bundle:true,format:'iife',target:'es2022',define:{__LIVE_DEMO__:String(demo)},minify:false});
 const html=(await fs.readFile(path.join(source,'index.html'),'utf8')).replace('<script src="live-config.js"></script><script src="../v3/vendor/supabase.js"></script>',demo?'':'<script src="../v3/config.js"></script><script src="../v3/vendor/supabase.js"></script>');
 await fs.writeFile(path.join(out,'index.html'),html);await fs.copyFile(path.join(source,'live.css'),path.join(out,'live.css'));
 if(demo){const css=await fs.readFile(path.join(out,'live.css'),'utf8'),js=await fs.readFile(path.join(out,'live.js'),'utf8');const standalone=html.replace('<link rel="stylesheet" href="live.css">',()=>'<style>'+css+'</style>').replace('<script type="module" src="live.js"></script>',()=>'<script>'+js.replace(/<\/script/gi,'<\\/script')+'</script>');const file=process.env.PULSO_LIVE_STANDALONE||path.join(root,'web','Pulso_LIVE_DEMO_ES.html');await fs.mkdir(path.dirname(file),{recursive:true});await fs.writeFile(file,standalone);}
}
console.log('Live monitor and standalone synthetic demonstration built; no backend changed.');
