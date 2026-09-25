"""Bounded, idempotent source edits for the reviewed live integration. No database access."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
def edit(name,old,new):
 p=root/name;s=p.read_text()
 if new in s:return
 if s.count(old)!=1:raise RuntimeError('Source drift; stop: '+name)
 p.write_text(s.replace(old,new))
edit('v3/live/demo.mjs','valid_until:new Date(Date.now()+15000).toISOString()','valid_until:new Date(Date.parse(now)+15000).toISOString()')
edit('v3/live/app.mjs','function accept(value){display=value;if(value){',"function accept(value){display=value;$('admin-console').hidden=DEMO||!value?.can_internal;if(value){")
edit('v3/live/index.html','<button id="leave">Salir</button>','<a id="admin-console" class="control-link" href="control.html" hidden>Administrar códigos / informes</a><button id="leave">Salir</button>')
p=root/'v3/live/app.mjs';s=p.read_text()
if '// Restore live readers after bfcache without retaining expired displayed data.' not in s:
 s+='\n// Restore live readers after bfcache without retaining expired displayed data.\naddEventListener("pageshow",event=>{if(event.persisted)location.reload();});\n'
 p.write_text(s)
p=root/'v3/live/live.css';s=p.read_text()
if '.control-link{' not in s:
 s+='\n.control-link{font:inherit;font-size:12px;color:#b3fff0;border:1px solid #326a68;padding:9px 12px;border-radius:9px;text-decoration:none;display:inline-flex;align-items:center;min-height:44px}body.tv .control-link{font-size:10px;min-height:30px;padding:5px 8px}@media(min-width:1600px) and (min-height:900px){body.tv #city-tabs{padding-right:0}body.tv .tools{position:static;flex-wrap:wrap}}\n@media(min-width:2500px) and (min-height:1400px){body.tv .heading h1{font-size:45px}body.tv .masthead{flex-basis:90px}body.tv .four .candidate-name{font-size:38px}body.tv .four .candidate-title strong{font-size:48px}body.tv .four .city-head{flex-basis:80px}body.tv .four .city-head h2{font-size:40px}body.tv .four .city-content{grid-template-columns:minmax(0,1fr) 330px}body.tv .four .donut{max-width:320px;width:320px;height:320px}body.tv .four .candidate-line{margin-bottom:18px}body.tv .four .candidate-n{font-size:17px}body.tv .four .metrics{flex-basis:76px}body.tv .four .metric b{font-size:34px}body.tv .four .metric span,body.tv .four .other,body.tv .four .city-foot{font-size:15px}}\n'
 p.write_text(s)
p=root/'v3/live/build.mjs';s=p.read_text()
if 'const consoleOut=' not in s:
 s+='\nconst consoleOut=path.join(root,"web/live");\nawait build({entryPoints:[path.join(source,"control.mjs")],outfile:path.join(consoleOut,"control.js"),bundle:true,format:"iife",target:"es2022",minify:false});\nfor(const file of ["control.html","control.css"])await fs.copyFile(path.join(source,file),path.join(consoleOut,file));\n'
 p.write_text(s)
print('Reviewed live console, responsive layout and resume edits prepared; no database connection.')
