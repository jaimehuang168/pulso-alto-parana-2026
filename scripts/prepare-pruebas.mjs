/** Copy accepted static builds to an opt-in existing-project test entry. No cloud mutations. */
import fs from 'node:fs/promises';import path from 'node:path';import {fileURLToPath} from 'node:url';import crypto from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),web=path.join(root,'web'),dest=path.join(web,'pruebas/ensayo');
// Private documentation is never published, including the older test-center route.
await fs.rm(path.join(web,'pruebas/guia-zh.html'),{force:true});
for(const relative of ['pruebas/index.html','pruebas/ensayo/index.html']){
 const file=path.join(web,relative);let html=await fs.readFile(file,'utf8');
 html=html.replace(/<a\b[^>]*href="(?:\.\.\/)?guia-zh\.html"[^>]*>[\s\S]*?<\/a>/g,'<a href="'+(relative.includes('ensayo/')?'../../v3/manual-es.html':'../v3/manual-es.html')+'">Manual de uso en español</a>');
 html=html.replace(/Active V3 únicamente en esa copia/gi,'Utilice la instalación de ensayo preparada').replace(/activar V3/gi,'preparar el ensayo');
 await fs.writeFile(file,html);
}
for(const folder of ['v3','live']){
 const src=path.join(web,folder),out=path.join(dest,folder);await fs.access(path.join(src,'index.html'));await fs.rm(out,{recursive:true,force:true});await fs.cp(src,out,{recursive:true});
 for(const file of folder==='v3'?['index.html']:['index.html','control.html']){
  const p=path.join(out,file);let html=await fs.readFile(p,'utf8'),entry=folder==='v3'?'app.js':file==='control.html'?'control.js':'live.js';
  html=html.replace(/<script src="(?:\.\.\/v3\/)?config\.js"><\/script>/g,'').replace(`<script type="module" src="${entry}"></script>`,'<script type="module" src="../../sandbox-launch.mjs"></script>').replace('</head>',`<meta name="pulso-test-entry" content="${entry}"></head>`);
  if(!html.includes('sandbox-launch.mjs')||/<script src="(?:\.\.\/v3\/)?config\.js">/.test(html))throw Error('TEST_ENTRY_BUILD_MISMATCH');
  await fs.writeFile(p,html);
 }
 if(folder==='v3')await fs.writeFile(path.join(out,'config.js'),"window.PULSO_V3_CONFIG={supabaseUrl:'',publishableKey:'',simulation:false};\n");
 await fs.rm(path.join(out,'manual-es-zh.html'),{force:true});
}
const hashes={};for(const f of ['v3/app.js','live/live.js','live/control.js']){const a=await fs.readFile(path.join(web,f)),b=await fs.readFile(path.join(dest,f));if(!a.equals(b))throw Error('RUNTIME_CHANGED');hashes[f]=crypto.createHash('sha256').update(b).digest('hex');}
await fs.writeFile(path.join(web,'pruebas/build-info.json'),JSON.stringify({feature:'pruebas-2',runtime_is_unchanged:true,creates_projects:false,changes_billing:false,activates_production:false,public_manual_language:'es',private_manual_included:false,source_runtime_hashes:hashes},null,2));
console.log('Spanish test center and existing-project trial entry prepared. No backend changes.');
