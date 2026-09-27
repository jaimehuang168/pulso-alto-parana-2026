"""Build Spanish and paragraph-aligned bilingual manuals from the reviewed source."""
from pathlib import Path
import json,html,base64,lzma,hashlib,re
from owner_only_access import apply_policy
from direct_use_policy import apply_direct_policy, NOTICE_ES, NOTICE_ZH
root=Path(__file__).resolve().parents[1]
parts=[root/f'docs/company-manual-part{i}.txt' for i in [1,2,3]]
source=root/'docs/company-manual-sections.json'
if all(p.exists() for p in parts):
 b=base64.b64decode(''.join(p.read_text().strip() for p in parts),validate=True)
 assert hashlib.sha256(b).hexdigest()=='a461f700fff8ab2dcc1938553d73ad294a16acee29de833b3b35280f7cf78ad6'
 source.write_bytes(lzma.decompress(b))
 for p in parts:p.unlink()
data=apply_direct_policy(apply_policy(json.loads(source.read_text())));assert len(data)==26 and sum(len(s['blocks']) for s in data)==131
css='''*{box-sizing:border-box}body{margin:0;font:18px/1.75 system-ui,Arial,sans-serif;color:#17333f;background:#f1f5f7}header{padding:38px max(24px,calc((100vw - 1120px)/2));background:#13353f;color:white}header small{letter-spacing:3px}h1{font-size:clamp(30px,5vw,48px);line-height:1.25}main{max-width:1120px;margin:auto;padding:24px}section,nav{background:white;border:1px solid #d4e1e5;border-radius:12px;padding:28px;margin-bottom:22px}h2{font-size:28px;line-height:1.35;color:#0c5c61}p{overflow-wrap:anywhere}.zh{font-size:17px;color:#415b64;border-left:3px solid #80b9ac;padding-left:18px}nav a{display:block;padding:6px;text-decoration:none}a{color:#066874}.pair{margin:24px 0}.note{background:#fff3d5;border-left:5px solid #d7a234;padding:18px}@media(max-width:600px){main{padding:14px}section,nav{padding:20px}body{font-size:17px}h2{font-size:24px}}@media print{body{background:white;font-size:11pt}header{background:white;color:#13353f;padding:10px 0}main{padding:0}section{border:0;padding:10px 0}nav{break-after:page}h2{break-after:avoid;font-size:18pt}.pair{break-inside:avoid}.zh{font-size:10.5pt}}'''
for bi in [False,True]:
 title='Manual de administración y uso'+(' / 管理與操作手冊' if bi else '')
 note='Edición 3.1.2 · 27 septiembre 2026. Publicar el cliente no instala el modo de acceso directo 014 ni certifica teléfonos físicos. Todos los ejemplos son sintéticos y no deben insertarse en producción.'
 if bi:note+='<br>網站發布不會自動安裝 014 直接使用模式，也不代表實體手機已驗收。範例均為合成資料，不可寫入正式庫。'
 note+='<br>'+html.escape(NOTICE_ES)
 if bi:note+='<br>'+html.escape(NOTICE_ZH)
 toc=''.join('<a href="#s'+s['id']+'">'+s['id']+' · '+html.escape(s['title_es'])+(' / '+html.escape(s['title_zh']) if bi else '')+'</a>' for s in data)
 sections=[]
 for s in data:
  text=''.join('<div class="pair"><p>'+html.escape(x['es'])+'</p>'+('<p class="zh">'+html.escape(x['zh'])+'</p>' if bi else '')+'</div>' for x in s['blocks'])
  sections.append('<section id="s'+s['id']+'"><h2>'+s['id']+' · '+html.escape(s['title_es'])+'</h2>'+('<p class="zh">'+html.escape(s['title_zh'])+'</p>' if bi else '')+text+'<a href="#indice">Volver al índice</a></section>')
 page='<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pulso 3.1.2 · '+title+'</title><style>'+css+'</style></head><body><header><small>PULSO · MANUAL 3.1.2</small><h1>'+title+'</h1><p>Configuración, usuarios, datos, trabajo de campo, informes y sincronización.</p></header><main><section><p class="note">'+note+'</p></section><nav id="indice"><h2>Índice</h2>'+toc+'</nav>'+''.join(sections)+'</main></body></html>'
 if not bi:assert not re.search('[\u3400-\u9fff]',page)
 for section in data:
  for block in section['blocks']:
   assert html.escape(block['es']) in page
   if bi:assert html.escape(block['zh']) in page
 (root/'v3/web'/('manual-es-zh.html' if bi else 'manual-es.html')).write_text(page)
print('26 chapters / 131 Spanish paragraphs / 131 aligned Traditional Chinese paragraphs; no Chinese in Spanish-only manual.')
