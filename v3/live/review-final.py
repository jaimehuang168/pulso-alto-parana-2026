"""Exact source-only review corrections. Does not connect to Supabase or publish data."""
from pathlib import Path
root=Path(__file__).resolve().parent
p=root/'app.mjs';s=p.read_text()
s=s.replace("function filename(ext){return 'Pulso_'+(DEMO?'DEMO_':display.private?'PRIVADO_NO_DIFUNDIR_':'CODIGOS_AUTORIZADO_')+(city==='all'?'4_CIUDADES':CITIES.find(c=>c.id===city).code)+'_'+display.server_time", "function filename(ext,data=display,scope=city){return 'Pulso_'+(DEMO?'DEMO_':data.private?'PRIVADO_NO_DIFUNDIR_':'CODIGOS_AUTORIZADO_')+(scope==='all'?'4_CIUDADES':CITIES.find(c=>c.id===scope).code)+'_'+data.server_time")
s=s.replace("const data=validate(display),svg=exportSVG(data,city,DEMO", "const data=validate(display),scope=city,savedName=filename('png',data,scope),svg=exportSVG(data,scope,DEMO")
s=s.replace("download(b,filename('png'),'image/png')", "download(b,savedName,'image/png')")
s=s.replace("const {data,error}=await sb.rpc('v3_live_board'", "const {data,error,status}=await sb.rpc('v3_live_board'")
s=s.replace("if(error)throw Object.assign(new Error(error.message),error);return data;", "if(error)throw Object.assign(new Error(error.message),error,{status});return data;")
p.write_text(s)
p=root/'core.mjs';s=p.read_text()
s=s.replace("const W=1920,H=four?1180:1080,margin=48,cols=four?2:1,gap=30,cw=(W-2*margin-gap*(cols-1))/cols,ch=four?444:720;", "const extra=Math.max(0,...cities.map(c=>c.candidates.length-4)),stepExtra=extra*(four?64:102);\n const W=1920,H=(four?1180:1080)+stepExtra*(four?2:1),margin=48,cols=four?2:1,gap=30,cw=(W-2*margin-gap*(cols-1))/cols,ch=(four?444:720)+stepExtra;")
marker='/** Cancelable single-flight reader.'
if marker in s:s=s[:s.index(marker)]
p.write_text(s)
print('Export captures audience and city before async work; auth status preserved; long lists not cropped.')
