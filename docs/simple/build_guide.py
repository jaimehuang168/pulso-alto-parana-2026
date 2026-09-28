"""Illustrated Spanish supplement from accepted native screenshots, before narration."""
from pathlib import Path
import argparse,json,html,hashlib,re
from PIL import Image,ImageDraw,ImageFont
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph
from reportlab.lib.colors import HexColor
PAPER=(595.28,841.89)
def build(screens,out):
 out.mkdir(parents=True,exist_ok=True);(out/'images').mkdir(exist_ok=True)
 course=json.loads((Path(__file__).parent/'course.json').read_text())
 # Coordinates are in actual screenshot pixels; checked against the visible save bar.
 for c in course['chapters']:
  for s in c['steps']:
   if s['id']=='U2.3':s['crop']=[0,1400,390,1860]
   if s['id']=='U1.1':
    s['image']='teaching-login-form.png';s['crop']=None
    s['text']='Use su teléfono personal con bloqueo de pantalla. Con Internet, abra el enlace del App terminado en /v3/. Escriba Código o correo y Contraseña que recibió, y pulse Ingresar una vez. No necesita una cuenta de correo nueva ni una segunda contraseña local.'
   source=screens/s['image'];im=Image.open(source).convert('RGB')
   if s['crop']:
    x,y,r,b=s['crop'];assert 0<=x<r<=im.width and 0<=y<b<=im.height,(s['id'],im.size,s['crop']);im=im.crop(s['crop'])
   if max(im.size)>1500:im.thumbnail((1500,1500))
   im=im.copy();s['figure']='paso_'+s['id']+'.jpg';im.save(out/'images'/s['figure'],quality=91)
   s['source_sha256']=hashlib.sha256(source.read_bytes()).hexdigest()
 (out/'course-es.json').write_text(json.dumps(course,ensure_ascii=False,indent=2))
 css='''*{box-sizing:border-box}body{margin:0;font:18px/1.7 system-ui,Arial,sans-serif;background:#f1f6f5;color:#163d46}header{background:#153e46;color:white;padding:32px max(20px,calc((100vw - 1040px)/2))}main{max-width:1080px;margin:auto;padding:24px}h1{font-size:clamp(28px,5vw,42px);line-height:1.25}h2{font-size:29px}h3{font-size:22px;margin:0}a{color:#067366}.step{background:white;border:1px solid #cfdfdf;border-radius:16px;padding:24px;margin:24px 0}.step img{max-width:100%;max-height:720px;display:block;margin:20px auto;border:1px solid #d4e2e0}.step small{display:block;color:#567379}.notice{background:#fff3d5;border-left:5px solid #bb8507;padding:20px}.buttons{display:flex;flex-wrap:wrap;gap:14px}nav a{display:block;padding:7px}section{scroll-margin:20px}footer{padding:24px;background:#dcebe6}video{display:block;width:100%;max-height:650px;background:#143e47}button,.button{display:inline-block;padding:10px 18px;background:#116b63;color:white;border-radius:9px;border:0;font-size:18px;text-decoration:none}@media(max-width:500px){main{padding:14px}.step{padding:18px}}@media print{header{background:white;color:#163d46}nav,video,.buttons{display:none}.step{break-inside:avoid}.step img{max-height:400px}body{font-size:11pt}}'''
 notice='Esta guía es para cuentas individuales con preparación automática. Sustituye los pasos anteriores de QR, frase local adicional e inicio manual para este modo. Los controles de apertura y los permisos siguen a cargo de la empresa. Si todavía no aparece Crear encuestador, la actualización técnica puede estar pendiente.'
 parts=['<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pulso · Ingreso personal</title><style>'+css+'</style></head><body><header><small>PULSO · INGRESO PERSONAL</small><h1>Una cuenta. Su teléfono. A encuestar.</h1><p>Guía ilustrada para administración y encuestadores.</p></header><main><p class="notice">'+notice+'</p><p>Las capturas proceden de pruebas aisladas con personas, lugares y respuestas ficticias. No copie esos datos en producción. Consulte los resultados que aparezcan en su propia instalación.</p><div class="buttons"><a class="button" href="Guia_Ingreso_Personal_ES.pdf">Descargar PDF</a><a class="button" href="videos.html">Ver los nuevos videos</a></div><nav>']
 parts += ['<a href="#s'+c['id']+'">'+html.escape(c['title'])+'</a>' for c in course['chapters']];parts+=['</nav>']
 for c in course['chapters']:
  parts+=['<section id="s'+c['id']+'"><h2>'+html.escape(c['title'])+'</h2><p>'+html.escape(c['goal'])+'</p>']
  for s in c['steps']:
   parts+=['<article class="step" id="paso-'+s['id']+'"><h3>'+s['id']+' · '+html.escape(s['title'])+'</h3><p>'+html.escape(s['text'])+'</p><img loading="lazy" src="images/'+s['figure']+'" alt="Paso '+s['id']+' · '+html.escape(s['title'],quote=True)+'"><small>Captura de formación, no datos de producción.</small></article>']
  parts+=['<p><strong>Resultado esperado: </strong>'+html.escape(c['result'])+'</p></section>']
 parts+=['<footer>No comparta contraseñas. No borre pendientes. Una recepción pendiente de revisión no equivale a una aceptación.</footer></main></body></html>']
 text=''.join(parts);assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail.com',text);(out/'index.html').write_text(text)
 def para(cv,text,x,y,w,size=12,color='#163d46'):
  p=Paragraph(html.escape(text),ParagraphStyle('p',fontName='Helvetica',fontSize=size,leading=size*1.45,textColor=HexColor(color)));_,h=p.wrap(w,700);p.drawOn(cv,x,y-h);return y-h
 cv=canvas.Canvas(str(out/'Guia_Ingreso_Personal_ES.pdf'),pagesize=PAPER);cv.setTitle('Pulso · Guía de ingreso personal');cv.setAuthor('Pulso');number=0
 for c in course['chapters']:
  for s in c['steps']:
   number+=1;W,H=PAPER;cv.setFillColor(HexColor('#163e46'));cv.rect(0,H-96,W,96,fill=1,stroke=0);cv.setFillColor(HexColor('#ffffff'));cv.setFont('Helvetica-Bold',13);cv.drawString(34,H-29,'PULSO · INGRESO PERSONAL');para(cv,c['title'],34,H-44,W-68,12,'#ffffff')
   y=para(cv,s['id']+' · '+s['title'],34,H-120,W-68,19);y=para(cv,s['text'],34,y-17,W-68,12)-18
   im=Image.open(out/'images'/s['figure']);avail=max(150,y-116);scale=min((W-68)/im.width,avail/im.height);iw,ih=im.width*scale,im.height*scale;cv.drawImage(ImageReader(im),(W-iw)/2,y-ih,width=iw,height=ih)
   para(cv,'Resultado: '+c['result'],34,91,W-68,9);cv.setFont('Helvetica',8);cv.setFillColor(HexColor('#567379'));cv.drawString(34,25,'Capturas ficticias de formación · No usar los ejemplos en producción');cv.drawRightString(W-34,25,str(number));cv.showPage()
 cv.save()
 import fitz
 doc=fitz.open(out/'Guia_Ingreso_Personal_ES.pdf');assert len(doc)==number==22
 for page,(c,s) in zip(doc,[(c,s) for c in course['chapters'] for s in c['steps']]):
  t=re.sub(r'\s+',' ',page.get_text());assert re.sub(r'\s+',' ',s['text']) in t and page.get_images(),s['id']
 (out/'document-checks.json').write_text(json.dumps({'pass':True,'chapters':len(course['chapters']),'steps':number,'pages':len(doc),'every_step_has_image_and_exact_text':True},indent=2))
 print('Built 22 verified illustrated steps.')
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--screens',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args();build(a.screens,a.out)
