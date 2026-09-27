"""Narrated training guides from actual synthetic UI captures. No production access."""
from pathlib import Path
import argparse,hashlib,json,math,re,subprocess,wave
from PIL import Image,ImageDraw,ImageFont,ImageOps
BG='#0b242d';ACCENT='#c8f67f';FG='#f3f9f8';MUTED='#a3c0c4'
def font(n,bold=False):return ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if bold else '')+'.ttf',n)
def wrap(d,text,f,width):
 lines=[];line=''
 for w in text.split():
  candidate=(line+' '+w).strip()
  if d.textlength(candidate,font=f)>width and line:lines.append(line);line=w
  else:line=candidate
 if line:lines.append(line)
 return lines
def paragraph(d,text,xy,f,width,fill=FG,gap=10,max_lines=None):
 lines=wrap(d,text,f,width)
 if max_lines and len(lines)>max_lines:raise ValueError('Text overflow: '+text)
 x,y=xy
 for line in lines:d.text((x,y),line,font=f,fill=fill);y+=f.size+gap
 return y
def frame(v,c,caption,images,index,count,path):
 w,h=v['size'];portrait=h>w;im=Image.new('RGB',(w,h),BG);d=ImageDraw.Draw(im)
 if portrait:
  d.text((54,40),'pulso',font=font(58,True),fill=FG);d.text((54,112),'GUÍA MÓVIL · 3.1.3',font=font(27),fill=MUTED);paragraph(d,c['title'],(54,170),font(45,True),972,gap=5,max_lines=3);area=(105,350,975,1500)
 else:
  d.text((48,25),'pulso  /  CAPACITACIÓN',font=font(31,True),fill=FG);d.text((1330,31),'DATOS FICTICIOS · 3.1.3',font=font(25),fill=ACCENT);paragraph(d,c['title'],(48,77),font(46,True),1760,gap=6,max_lines=1);area=(48,164,1468,894)
 image=c.get('image')
 if image=='a_company_edit' and caption.startswith(('Guarde','Para corregir','Si otra')):image='a_company_saved'
 if image=='a_registry' and caption.startswith(('Ver detalle','Los datos pendientes')):image='a_record_detail'
 if image:
  source=Image.open(images/(image+'.png')).convert('RGB');x1,y1,x2,y2=area;source=ImageOps.contain(source,(x2-x1,y2-y1),Image.Resampling.LANCZOS);x=x1+(x2-x1-source.width)//2;y=y1+(y2-y1-source.height)//2;d.rounded_rectangle((x-8,y-8,x+source.width+8,y+source.height+8),radius=16,fill='#c0d5d5');im.paste(source,(x,y));d=ImageDraw.Draw(im)
 else:
  x1,y1,x2,y2=area;d.rounded_rectangle((x1,y1,x2,y2),radius=32,fill='#153d46');paragraph(d,'APRENDER Y COMPROBAR',(x1+55,y1+90),font(70 if not portrait else 68,True),x2-x1-110,max_lines=3);paragraph(d,c['note'],(x1+55,y1+290),font(42),x2-x1-110,fill=ACCENT,gap=22,max_lines=5);paragraph(d,'Pantallas reales de la aplicación. Datos de formación. No es un resultado electoral.',(x1+55,y2-195),font(30),x2-x1-110,fill=MUTED,max_lines=4)
 if portrait:
  for j,line in enumerate(wrap(d,c['note'],font(26,True),980)[:2]):d.text((54,285+j*32),line,font=font(26,True),fill=ACCENT)
  d.rectangle((0,1530,w,1835),fill='#061820');paragraph(d,caption,(60,1557),font(43),960,gap=11,max_lines=5);d.text((54,1854),'FORMACIÓN · VOZ SINTÉTICA · NO OFICIAL',font=font(23),fill=MUTED)
 else:
  d.text((1520,200),'EN ESTE PASO',font=font(24,True),fill=MUTED);paragraph(d,c['note'],(1520,255),font(36,True),345,gap=18,fill=ACCENT,max_lines=9);paragraph(d,'Pause el video para repetir cada paso.',(1520,732),font(26),345,gap=10,fill=MUTED,max_lines=4);d.rectangle((0,916,w,1048),fill='#061820');paragraph(d,caption,(55,932),font(37),1810,gap=9,max_lines=2);d.text((55,1052),'PANTALLAS DE FORMACIÓN · NARRACIÓN SINTÉTICA · NO ES UNA PRUEBA DE PRODUCCIÓN',font=font(17),fill=MUTED)
 d.rectangle((0,h-9,w,h),fill='#244951');d.rectangle((0,h-9,int(w*(index+1)/count),h),fill=ACCENT);im.save(path)
def sentences(paragraphs,limit=165):
 result=[]
 for p in paragraphs:
  for sent in re.split(r'(?<=[.!?])\s+(?=[A-ZÁÉÍÓÚÜÑ¿¡])',p.strip()):
   if len(sent)<=limit:result.append(sent);continue
   part=''
   for word in sent.split():
    if len(part)+len(word)+1>limit:result.append(part);part=word
    else:part=(part+' '+word).strip()
   if part:result.append(part)
 return result
def timestamp(s,comma=False):
 ms=round(s*1000);return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02}{"," if comma else "."}{ms%1000:03}'
def run(cmd):
 p=subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 if p.returncode:raise RuntimeError(p.stderr.decode(errors='replace')[-5000:])
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--scenes',type=Path,required=True);ap.add_argument('--images',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--model',type=Path);ap.add_argument('--preview-only',action='store_true');a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True);data=json.loads(a.scenes.read_text());manifest={'version':data['version'],'language':'es','disclosure':data['disclosure'],'source_basis':data['basis'],'narration':'Piper es_MX-ald-medium; synthetic voice','capture_run':36353637989,'videos':[]}
 if not a.preview_only:
  from piper import PiperVoice,SynthesisConfig
  if not a.model:raise ValueError('Piper model required')
  voice=PiperVoice.load(str(a.model));synthesis=SynthesisConfig(length_scale=1.04,noise_scale=0.55,noise_w_scale=0.7)
 for v in data['videos']:
  work=a.out/('_'+v['id']);work.mkdir(exist_ok=True);clips=[];cues=[];chapters=[];elapsed=0;transcript=[];segments=[]
  for ci,c in enumerate(v['chapters']):
   for text in sentences(c['lines'],150 if v['id']=='usuarios' else 195):segments.append((ci,c,text))
  for k,(ci,c,text) in enumerate(segments):
   pic=work/f'{k:03}.png';frame(v,c,text,a.images,k,len(segments),pic)
   if a.preview_only:continue
   wav=work/f'{k:03}.wav'
   with wave.open(str(wav),'wb') as dest:voice.synthesize_wav(text,dest,syn_config=synthesis)
   with wave.open(str(wav),'rb') as src:
    n=src.getnframes();rate=src.getframerate();duration=n/rate;assert n>rate*0.3 and src.getnchannels()==1
   duration=math.ceil((duration+0.45)*12)/12
   if not chapters or chapters[-1]['title']!=c['title']:chapters.append({'title':c['title'],'start':round(elapsed,3),'note':c['note']});transcript+=['',timestamp(elapsed)+'  '+c['title']]
   transcript.append(text);cues.append((elapsed,elapsed+duration,text));elapsed+=duration;clip=work/f'{k:03}.mkv'
   run(['ffmpeg','-y','-hide_banner','-loglevel','error','-loop','1','-framerate','12','-i',str(pic),'-i',str(wav),'-t',str(duration),'-vf','fade=t=in:st=0:d=0.12','-af','apad,loudnorm=I=-16:TP=-1.5:LRA=9','-r','12','-c:v','libx264','-preset','veryfast','-tune','stillimage','-crf','23','-pix_fmt','yuv420p','-c:a','pcm_s16le','-ar','48000','-ac','1','-threads','2',str(clip)]);clips.append(clip);print(v['id'],k+1,'/',len(segments),round(elapsed,1),flush=True)
  name='Pulso_313_'+('Admin' if v['id']=='admin' else 'Usuarios')+'_ES';poster=a.out/(name+'.jpg');Image.open(work/'000.png').convert('RGB').save(poster,quality=90)
  if a.preview_only:continue
  listing=work/'concat.txt';listing.write_text('\n'.join("file '"+str(p.resolve())+"'" for p in clips));final=a.out/(name+'.mp4');meta=work/'chapters.txt';mt=[';FFMETADATA1','title='+v['title'],'language=spa','comment=Formación con datos ficticios; narración sintética.']
  for i,ch in enumerate(chapters):mt+=['[CHAPTER]','TIMEBASE=1/1000','START='+str(round(ch['start']*1000)),'END='+str(round((chapters[i+1]['start'] if i+1<len(chapters) else elapsed)*1000)),'title='+ch['title']]
  meta.write_text('\n'.join(mt));run(['ffmpeg','-y','-hide_banner','-loglevel','error','-f','concat','-safe','0','-i',str(listing),'-i',str(meta),'-map_metadata','1','-map_chapters','1','-c:v','copy','-c:a','aac','-b:a','96k','-movflags','+faststart',str(final)])
  srt=a.out/(name+'.srt');vtt=a.out/(name+'.vtt');srt.write_text('\n\n'.join(f'{i+1}\n{timestamp(s,True)} --> {timestamp(e,True)}\n{text}' for i,(s,e,text) in enumerate(cues))+'\n');vtt.write_text('WEBVTT\n\n'+'\n\n'.join(f'{timestamp(s)} --> {timestamp(e)}\n{text}' for s,e,text in cues)+'\n');(a.out/(name+'_Guion.txt')).write_text('\n'.join(transcript)+'\n')
  info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-show_chapters','-of','json',str(final)],text=True));vs=next(s for s in info['streams'] if s['codec_type']=='video');au=next(s for s in info['streams'] if s['codec_type']=='audio');actual=float(info['format']['duration']);assert vs['codec_name']=='h264' and au['codec_name']=='aac';assert [vs['width'],vs['height']]==v['size'];assert abs(actual-elapsed)<len(clips)*0.05+1;assert len(info['chapters'])==len(chapters);assert final.stat().st_size<95000000
  run(['ffmpeg','-hide_banner','-v','error','-i',str(final),'-f','null','-']);manifest['videos'].append({'id':v['id'],'title':v['title'],'file':final.name,'poster':poster.name,'subtitles':vtt.name,'srt':srt.name,'transcript':name+'_Guion.txt','duration_seconds':round(actual,3),'dimensions':v['size'],'bytes':final.stat().st_size,'sha256':sha(final),'chapters':chapters,'checks':{'h264_aac':True,'full_decode':True,'embedded_chapters':True,'caption_cues':len(cues)}})
  import shutil;shutil.rmtree(work)
 if not a.preview_only:
  manifest['scene_sha256']=sha(a.scenes);manifest['files']={p.name:sha(p) for p in a.out.iterdir() if p.is_file()};(a.out/'tutorials.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2));print(json.dumps(manifest,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
