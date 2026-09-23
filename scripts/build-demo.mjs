import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const read=n=>fs.readFileSync(path.join(root,'web',n),'utf8');
let html=read('index.html');
html=html.replace('<title>Pulso • Boca de urna | Alto Paraná</title>','<title>Pulso • DEMOSTRACIÓN | Alto Paraná</title>')
 .replace('<link rel="manifest" href="manifest.webmanifest">','')
 .replace('<link rel="icon" type="image/svg+xml" href="icon.svg">','<link rel="icon" href="data:image/svg+xml;base64,'+Buffer.from(read('icon.svg')).toString('base64')+'">')
 .replace('<link rel="stylesheet" href="styles.css">',()=>'<style>'+read('styles.css')+'</style>')
 .replace('<script src="config.js"></script>','<script>window.PULSO_CONFIG={defaultDemo:true,allowDemo:true,standalone:true,version:"2.0.0",supabaseUrl:"",supabasePublishableKey:""};</script>');
for(const n of ['core.js','app.js'])html=html.replace(`<script src="${n}"></script>`,()=>'<script>'+read(n).replace(/<\/script/gi,'<\\/script')+'</script>');
const target=process.argv[2]||path.join(root,'DEMO_ABRIR_EN_NAVEGADOR.html');fs.writeFileSync(target,html);console.log('Demo creada:',target);
