"""Public Spanish-only training documents. No private translations are read or emitted."""
from pathlib import Path
import csv,json,html,hashlib,re,argparse
from PIL import Image,ImageDraw,ImageFont
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Image as Picture,PageBreak,KeepTogether
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
REG='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';BOLD='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
pdfmetrics.registerFont(TTFont('Guide',REG));pdfmetrics.registerFont(TTFont('GuideB',BOLD));pdfmetrics.registerFontFamily('Guide',normal='Guide',bold='GuideB')
E=html.escape

def read_course(src):
 chapters=[]
 for n in [1,2,3]:
  for row in csv.reader((src/f'lessons-{n}.tsv').open(),delimiter='\t'):
   if row[0].startswith('@'):
    assert len(row)==8
    chapter=dict(zip(['id','audience','title','goal','before','result','warning','screen_note'],[row[0][1:]]+row[1:]));chapter['steps']=[];chapters.append(chapter)
   else:
    assert len(row)==6
    step=dict(zip(['id','image','focus','title','text'],row[:5]));crop=json.loads(row[5])
    if crop:step['crop']=crop
    chapter['steps'].append(step)
 d={'version':'3.1.3','edition':'Guía visual R2 · 28 septiembre 2026','language':'es','source_commit':'74a46e6ba3698646f7f50ab254c2a60ef39353a2','disclosure':'Capturas actuales con datos sintéticos. No es una grabación continua ni una prueba de producción.','chapters':chapters,'step_count':sum(len(c['steps']) for c in chapters)}
 assert len(chapters)==26 and d['step_count']==147
 for c in chapters:assert [s['id'] for s in c['steps']]==[c['id']+'.'+str(i+1) for i in range(len(c['steps']))]
 assert not re.search('[\u3400-\u9fff]',json.dumps(d,ensure_ascii=False))
 return d

def prepare_images(d,screens,out):
 out.mkdir(parents=True,exist_ok=True);meta=json.loads((screens/'read/screens.json').read_text())['screens'];manifest=[]
 for c in d['chapters']:
  for s in c['steps']:
   source=screens/(s['image']+'.png');im=Image.open(source).convert('RGB');w,h=im.size
   if s.get('crop'):
    x,y,right,bottom=s['crop'];assert 0<=x<right<=w and 0<=y<bottom<=h;im=im.crop((x,y,right,bottom));w,h=im.size
   boxes=[];focus=s['focus']
   if s['image'].startswith('read/') and focus:
    for f in meta[s['image'].split('/')[1]]['fields']:
     match=focus in [f.get('name'),f.get('id'),f.get('action'),f.get('label')]
     if focus=='session':match='Sesión iniciada' in f.get('label','')
     if match and f['x']>=0 and f['y']>=0 and f['x']+f['w']<=w+2 and f['y']+f['h']<=h+2:boxes.append(f)
   draw=ImageDraw.Draw(im)
   for b in boxes[:2]:draw.rounded_rectangle((max(2,b['x']-3),max(2,b['y']-3),min(w-2,b['x']+b['w']+3),min(h-2,b['y']+b['h']+3)),radius=7,outline='#e68b12',width=4)
   bh=40 if w>650 else 32;band=Image.new('RGB',(w,h+bh),'#153f48');band.paste(im,(0,bh));ImageDraw.Draw(band).text((12,8),f"PASO {s['id']}  |  PANTALLA DE FORMACIÓN",font=ImageFont.truetype(BOLD,18 if w>650 else 13),fill='white')
   name='paso_'+s['id'].replace('.','_')+'.jpg';band.save(out/name,quality=92,optimize=True);s['figure']=name
   manifest.append({'step':s['id'],'image':name,'source':s['image']+'.png','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'sha256':hashlib.sha256((out/name).read_bytes()).hexdigest(),'exact_dom_highlights':len(boxes[:2])})
 return manifest

CSS='''*{box-sizing:border-box}body{margin:0;background:#edf3f4;color:#173c45;font:19px/1.75 system-ui,Arial,sans-serif}header{background:#123b44;color:#fff;padding:36px max(22px,calc((100vw - 1120px)/2))}h1{font-size:clamp(30px,5vw,48px);line-height:1.25}h2{font-size:29px;line-height:1.3}h3{font-size:23px;line-height:1.45}main{max-width:1140px;padding:22px;margin:auto}.intro,nav,section{background:white;border:1px solid #cedee0;border-radius:14px;padding:26px;margin-bottom:24px}nav a{display:block;padding:7px 0;color:#096e67}.pill{font-size:14px;letter-spacing:2px}.notice{padding:14px 18px;border-left:5px solid #d89422;background:#fff6e4}.success{padding:14px 18px;border-left:5px solid #168573;background:#ebf6ef}.step{border-top:1px solid #dbe7e9;padding:22px 0 12px}.step b{font-size:16px;background:#14766d;color:#fff;padding:5px 10px;border-radius:8px;margin-right:8px}figure{margin:18px 0;background:#f2f6f6;padding:12px;border-radius:12px;text-align:center}figure img{display:block;max-width:100%;max-height:780px;width:auto;height:auto;margin:auto;cursor:zoom-in}figcaption{font-size:14px;line-height:1.5;text-align:left;color:#536a71;margin-top:10px}a{color:#076d66}.back{font-size:16px}.lead{font-size:21px}.toc{columns:2;column-gap:28px}@media(max-width:640px){main{padding:12px}.intro,nav,section{padding:20px}body{font-size:18px}.toc{columns:1}h2{font-size:26px}h3{font-size:21px}figure{margin:12px -8px}}@media print{body{background:#fff;font-size:11pt}header{background:#fff;color:#173c45;padding:0}main{max-width:none;padding:0}.intro,nav,section{border:0;padding:0}section{break-before:page}figure img{max-height:310px}.step{break-inside:avoid}.back{display:none}}'''

def make_html(d,out):
 intro='<p class="lead">No necesita conocimientos técnicos. Use el enlace y la cuenta individual entregados por la empresa.</p><p>Pulse significa hacer clic en una computadora o tocar con el dedo en un teléfono. Si el botón está más abajo, deslice la pantalla.</p><p>Lea Objetivo y Antes de comenzar. Siga los pasos en orden y compruebe el resultado al final. Los números coinciden con el manual PDF y los videos.</p><p class="notice">Capturas actuales con datos ficticios de formación; no son resultados electorales. Un formulario vacío muestra dónde escribir, no demuestra un envío. No copie nombres, referencias o cifras DEMO al trabajo real.</p><p>Toque una imagen para abrirla a tamaño completo. Cada paso tiene su captura. Los recuadros ámbar, cuando existen, marcan controles reales. Algunos pasos describen estados que aparecen solo cuando falta completar un requisito.</p><p><a href="Manual_Admin_ES.pdf">Manual de administración PDF</a> · <a href="Manual_Usuarios_ES.pdf">Manual de usuarios PDF</a> · <a href="index.html">Videos paso a paso</a></p>'
 toc=''.join(f'<a href="#s{c["id"]}">{c["id"]}. {E(c["title"])}</a>' for c in d['chapters']);blocks=[]
 for c in d['chapters']:
  t=f'<section id="s{c["id"]}"><span class="pill">{"ADMINISTRACIÓN" if c["audience"]=="admin" else "ENCUESTADORES Y VIEWER"}</span><h2>{c["id"]}. {E(c["title"])}</h2><p><strong>Objetivo:</strong> {E(c["goal"])}</p><p><strong>Antes de comenzar:</strong> {E(c["before"])}</p>'
  for s in c['steps']:t+=f'<article class="step" id="paso-{s["id"]}"><h3><b>{s["id"]}</b>{E(s["title"])}</h3><p>{E(s["text"])}</p><figure><a href="images/{s["figure"]}" target="_blank" rel="noopener"><img src="images/{s["figure"]}" alt="Paso {s["id"]}: {E(s["title"])}" loading="lazy"></a><figcaption>{E(c["screen_note"])}</figcaption></figure></article>'
  t+=f'<p class="success"><strong>Resultado que debe comprobar:</strong> {E(c["result"])}</p><p class="notice"><strong>Evite este error:</strong> {E(c["warning"])}</p><a class="back" href="#indice">Volver al índice</a></section>';blocks.append(t)
 page='<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pulso · Manual visual paso a paso R2</title><style>'+CSS+'</style></head><body><header><span class="pill">PULSO 3.1.3 · GUÍA VISUAL R2</span><h1>Manual visual paso a paso</h1><p>26 capítulos · 147 pasos ilustrados · 28 septiembre 2026</p></header><main><div class="intro">'+intro+'</div><nav id="indice"><h2>Busque la tarea que necesita</h2><div class="toc">'+toc+'</div></nav>'+''.join(blocks)+'</main></body></html>'
 assert not re.search('[\u3400-\u9fff]',page);out.write_text(page)

def groups(c):
 out=[]
 for s in c['steps']:
  if out and out[-1][0]['image']==s['image'] and len(out[-1])<3:out[-1].append(s)
  else:out.append([s])
 return out

def make_pdf(d,folder,path,audience=None):
 chapters=[c for c in d['chapters'] if audience is None or c['audience']==audience];label='Administración' if audience=='admin' else 'Encuestadores y Viewer' if audience=='usuarios' else 'Manual completo'
 styles={k:ParagraphStyle(k,fontName='GuideB' if k in ['title','h'] else 'Guide',fontSize=sz,leading=lead,spaceAfter=8,textColor=HexColor('#173c45')) for k,sz,lead in [('title',28,35),('h',22,29),('body',11.5,17.5),('small',8.5,12),('step',12,18),('toc',11,17)]}
 def p(text,k='body'):return Paragraph(text,styles[k])
 def picture(name,mh):
  f=folder/'images'/name;w,h=Image.open(f).size;mh=max(mh,400) if h/w>1.5 else mh;r=min(510/w,mh/h);return Picture(str(f),w*r,h*r,hAlign='CENTER')
 story=[Spacer(1,36),p('PULSO 3.1.3 · GUÍA VISUAL R2','small'),p('Manual visual<br/>paso a paso','title'),p(label,'h'),p(f'{len(chapters)} capítulos · {sum(len(c["steps"]) for c in chapters)} pasos ilustrados'),Spacer(1,12),picture(chapters[0]['steps'][4 if audience!='usuarios' else 0]['figure'],240),Spacer(1,18),p('Dónde entrar, qué pulsar, qué escribir y cómo comprobar el resultado. No necesita conocimientos técnicos.'),p('28 septiembre 2026 · Capturas actuales y datos sintéticos.','small'),PageBreak(),p('Cómo utilizar el manual','h')]
 for text in ['Prepare su enlace y cuenta individual. Pulse significa hacer clic o tocar la pantalla.','Busque el capítulo por tarea. Lea Objetivo y Antes de comenzar, y siga el orden numerado.','Compare la pantalla con la imagen; puede acercar el PDF. Los recuadros ámbar señalan controles reales.','No copie datos DEMO al operativo real. Un formulario mostrado no demuestra que ya se haya enviado.','Compruebe el resultado esperado. No cree duplicados para resolver un permiso o un dato que falta.','Los videos y este manual comparten los mismos identificadores de paso. Puede pausar el video en cualquier momento.']:story.append(p(text))
 story.append(p('Índice','h'))
 for c in chapters:story.append(p(f'<link href="#cap-{c["id"]}" color="#08776d">{c["id"]}. {E(c["title"])}</link>','toc'))
 for c in chapters:
  story += [PageBreak(),p(f'<a name="cap-{c["id"]}"/>{c["id"]}. {E(c["title"])}','h'),p('<b>Objetivo.</b> '+E(c['goal'])),p('<b>Antes de comenzar.</b> '+E(c['before']))]
  for chunk in groups(c):
   rep=next((x for x in chunk if x.get('focus')),chunk[0]);block=[Spacer(1,6),picture(rep['figure'],310 if len(chunk)==1 else 265),p(E(c['screen_note']),'small')]
   for s in chunk:block.append(p(f'<b>{s["id"]} · {E(s["title"])}</b><br/>{E(s["text"])}','step'))
   h=sum(x.wrap(510,10000)[1] for x in block)+20
   if h<700:story.append(KeepTogether(block))
   else:
    for s in chunk:story.append(KeepTogether([picture(s['figure'],260),p(f'<b>{s["id"]} · {E(s["title"])}</b><br/>{E(s["text"])}','step')]))
  story.extend([p('<b>Resultado que debe comprobar.</b> '+E(c['result'])),p('<b>Evite este error.</b> '+E(c['warning']))])
 def footer(cv,doc):
  cv.setStrokeColor(HexColor('#d2e2e4'));cv.line(40,39,A4[0]-40,39);cv.setFont('Guide',8);cv.setFillColor(HexColor('#516c74'));cv.drawString(40,25,'PULSO · Guía visual R2 · '+label);cv.drawRightString(A4[0]-40,25,str(doc.page));cv.drawRightString(A4[0]-40,A4[1]-24,'FORMACIÓN · DATOS FICTICIOS')
 SimpleDocTemplate(str(path),pagesize=A4,leftMargin=40,rightMargin=40,topMargin=43,bottomMargin=53,title='Pulso - Manual visual R2',author='Pulso',pageCompression=1).build(story,onFirstPage=footer,onLaterPages=footer)

def build(src,screens,out):
 out.mkdir(parents=True,exist_ok=True);d=read_course(src);manifest=prepare_images(d,screens,out/'images');make_html(d,out/'manual.html')
 for name,audience in [('Manual_Admin_ES','admin'),('Manual_Usuarios_ES','usuarios'),('Manual_Completo_ES',None)]:make_pdf(d,out,out/(name+'.pdf'),audience)
 (out/'course-es.json').write_text(json.dumps(d,ensure_ascii=False,indent=2));(out/'manual-integrity.json').write_text(json.dumps({'chapters':26,'steps':147,'illustrated_steps':len(manifest),'private_material_included':False,'images':manifest},indent=2))
 return d
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--screens',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args();build(a.source,a.screens,a.out)
