"""Lively Spanish neural narration over reviewed current screenshots and exact lesson steps."""
from pathlib import Path
import argparse,asyncio,hashlib,json,math,re,subprocess,shutil
from PIL import Image,ImageDraw,ImageFont,ImageOps
VOICE='es-PY-TaniaNeural';RATE='+3%';PITCH='+4Hz'
BG='#eef4f5';INK='#143e47';TEAL='#0b776d'
def font(n,b=False):return ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if b else '')+'.ttf',n)
def lines(draw,text,f,width):
 out=[];current=''
 for word in text.split():
  new=(current+' '+word).strip()
  if current and draw.textlength(new,font=f)>width:out.append(current);current=word
  else:current=new
 if current:out.append(current)
 return out

def block(draw,text,x,y,width,size,fill=INK,b=False,maxheight=900,gap=10):
 f=font(size,b);rows=lines(draw,text,f,width);height=len(rows)*(size+gap);assert height<=maxheight,(text,height,maxheight)
 for row in rows:draw.text((x,y),row,font=f,fill=fill);y+=size+gap
 return y

def frame(step,ch,folder,path,portrait=False,index=0,total=1):
 W,H=(1080,1920) if portrait else (1920,1080);im=Image.new('RGB',(W,H),BG);dr=ImageDraw.Draw(im);dr.rectangle((0,0,W,112 if not portrait else 155),fill=INK)
 dr.text((44,22),'pulso · GUÍA VISUAL R2',font=font(30 if not portrait else 37,True),fill='white')
 block(dr,ch['id']+' · '+ch['title'],44,65,W-88,24 if not portrait else 29,fill='#bbd9d8',maxheight=88,gap=5)
 if portrait:
  block(dr,'PASO '+step['id'],44,181,992,30,TEAL,True,maxheight=45);block(dr,step['title'],44,239,992,43,b=True,maxheight=156,gap=8);area=(42,409,1038,1320);tx,ty,tw,ts,th=48,1360,984,34,365
 else:
  dr.rounded_rectangle((44,135,237,195),radius=16,fill=TEAL);dr.text((65,149),'PASO '+step['id'],font=font(29,True),fill='white');block(dr,step['title'],270,143,1590,39,b=True,maxheight=70);area=(44,234,1240,914);tx,ty,tw,ts,th=1300,280,570,29,550;dr.text((1300,235),'QUÉ HACER',font=font(23,True),fill=TEAL)
 source=Image.open(folder/'images'/step['figure']).convert('RGB');x1,y1,x2,y2=area;pic=ImageOps.contain(source,(x2-x1,y2-y1),Image.Resampling.LANCZOS);x=x1+(x2-x1-pic.width)//2;y=y1+(y2-y1-pic.height)//2;dr.rounded_rectangle((x-6,y-6,x+pic.width+6,y+pic.height+6),radius=9,fill='#ccdce0');im.paste(pic,(x,y));dr=ImageDraw.Draw(im)
 block(dr,step['text'],tx,ty,tw,ts,maxheight=th,gap=11)
 if not portrait:block(dr,'Pause el video para realizar este paso. Luego, continúe.',1300,837,570,21,fill='#536e77',maxheight=75,gap=8)
 dr.rectangle((0,H-(170 if portrait else 127),W,H),fill=INK);dr.text((40,H-40),'CAPTURAS DE FORMACIÓN · VOZ SINTÉTICA · NO OFICIAL',font=font(20 if portrait else 18),fill='#aac6c8')
 dr.rectangle((0,H-8,W,H),fill='#a8c1c4');dr.rectangle((0,H-8,int(W*(index+1)/total),H),fill='#91d6a6');im.save(path)

def call(args):
 r=subprocess.run(args,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace')[-3000:])
def duration(p):return float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',str(p)],text=True))
def stamp(t,comma=False):
 ms=round(t*1000);return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02}{"," if comma else "."}{ms%1000:03}'
def ass_time(t):
 cent=round(t*100);return f'{cent//360000}:{cent//6000%60:02}:{cent//100%60:02}.{cent%100:02}'
def subtitle_cues(events,end,limit):
 cues=[];words=[];start=0;last=0
 for x in events:
  if x['type']!='WordBoundary':continue
  t=x['offset']/10_000_000;finish=(x['offset']+x['duration'])/10_000_000;text=x['text']
  if words and (len(' '.join(words+[text]))>limit or t-last>0.8):cues.append((start,min(end,last+0.10),' '.join(words)));words=[]
  if not words:start=max(0,t)
  words.append(text);last=finish
 if words:cues.append((start,min(end,last+0.15),' '.join(words)))
 assert cues and all(0<=a<b<=end for a,b,_ in cues)
 return cues

def ass_file(cues,path,portrait):
 w,h=(1080,1920) if portrait else (1920,1080);size=35 if portrait else 32;bottom=65 if portrait else 48
 header=f'''[Script Info]\nScriptType: v4.00+\nPlayResX: {w}\nPlayResY: {h}\nWrapStyle: 0\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,DejaVu Sans,{size},&H00FFFFFF,&H000000FF,&H001B302F,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,45,45,{bottom},1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'''
 path.write_text(header+''.join(f'Dialogue: 0,{ass_time(a)},{ass_time(b)},Default,,0,0,0,,{t.replace(chr(10)," ").replace(chr(123),"(").replace(chr(125),")")}\n' for a,b,t in cues))

async def synthesize(jobs):
 import edge_tts
 semaphore=asyncio.Semaphore(3)
 async def one(job):
  _,_,text,audio,meta=job
  async with semaphore:
   for attempt in range(3):
    try:
     events=[]
     with audio.open('wb') as f:
      speech=edge_tts.Communicate(text,VOICE,rate=RATE,pitch=PITCH,boundary='WordBoundary',receive_timeout=90)
      async for part in speech.stream():
       if part['type']=='audio':f.write(part['data'])
       elif part['type']=='WordBoundary':events.append(part)
     assert audio.stat().st_size>2000 and events;meta.write_text(json.dumps(events,ensure_ascii=False));return
    except Exception:
     audio.unlink(missing_ok=True)
     if attempt==2:raise
     await asyncio.sleep(3+attempt*4)
 await asyncio.gather(*(one(j) for j in jobs))

def render(folder,out,audience,preview=False):
 out.mkdir(parents=True,exist_ok=True);d=json.loads((folder/'course-es.json').read_text());chapters=[c for c in d['chapters'] if c['audience']==audience];portrait=audience=='usuarios';work=out/('_'+audience);work.mkdir(exist_ok=True);jobs=[]
 for c in chapters:
  for i,s in enumerate(c['steps']):
   text=s['title']+'. '+s['text']
   if i==0:text=('¡Vamos paso a paso! ' if c==chapters[0] else 'Ahora, '+c['title']+'. ')+text
   if i==len(c['steps'])-1:text+=' Compruebe el resultado: '+c['result']
   if c==chapters[0] and i==0:text='Bienvenido a Pulso. Esta guía usa pantallas de formación y una voz sintética en español de Paraguay. Puede pausar y volver a cada paso. '+text
   jobs.append((c,s,text,work/(s['id']+'.mp3'),work/(s['id']+'.json')))
 for k,(c,s,text,audio,meta) in enumerate(jobs):frame(s,c,folder,work/(s['id']+'.png'),portrait,k,len(jobs))
 if preview:return
 asyncio.run(synthesize(jobs));elapsed=0;cues=[];cuts=[];steps=[];clips=[];script=[]
 for k,(c,s,text,audio,meta) in enumerate(jobs):
  sound=duration(audio);length=math.ceil((sound+0.75)*10)/10;events=json.loads(meta.read_text());local=subtitle_cues(events,sound,78 if portrait else 135);ass=work/(s['id']+'.ass');ass_file(local,ass,portrait)
  if not cuts or cuts[-1]['id']!=c['id']:cuts.append({'id':c['id'],'title':c['title'],'start':round(elapsed,3),'note':c['goal']})
  steps.append({'id':s['id'],'title':s['title'],'start':round(elapsed,3),'end':round(elapsed+length,3),'figure':'images/'+s['figure']});script += [f'\n{stamp(elapsed)} · PASO {s["id"]} · {s["title"]}',text];cues.extend((a+elapsed,b+elapsed,t) for a,b,t in local)
  clip=work/(s['id']+'.mkv');call(['ffmpeg','-y','-hide_banner','-loglevel','error','-loop','1','-framerate','10','-i',str(work/(s['id']+'.png')),'-i',str(audio),'-t',str(length),'-vf','subtitles='+str(ass),'-af','apad,loudnorm=I=-16:TP=-1.5:LRA=9','-r','10','-c:v','libx264','-preset','veryfast','-tune','stillimage','-crf','23','-pix_fmt','yuv420p','-c:a','pcm_s16le','-ar','48000','-ac','1','-threads','2',str(clip)]);clips.append(clip);elapsed+=length;print(audience,k+1,'/',len(jobs),round(elapsed,1),flush=True)
 name='Pulso_313_'+('Admin' if audience=='admin' else 'Usuarios')+'_ES_R2';listing=work/'concat.txt';listing.write_text('\n'.join("file '"+str(x.resolve())+"'" for x in clips));mt=[';FFMETADATA1','title=Pulso - Guía visual paso a paso R2','language=spa','comment=Capturas actuales con datos ficticios. Voz sintética de formación.']
 for i,c in enumerate(cuts):mt+=['[CHAPTER]','TIMEBASE=1/1000','START='+str(round(c['start']*1000)),'END='+str(round((cuts[i+1]['start'] if i+1<len(cuts) else elapsed)*1000)),'title='+c['title']]
 chapterfile=work/'chapters.txt';chapterfile.write_text('\n'.join(mt));final=out/(name+'.mp4');call(['ffmpeg','-y','-hide_banner','-loglevel','error','-f','concat','-safe','0','-i',str(listing),'-i',str(chapterfile),'-map_metadata','1','-map_chapters','1','-c:v','copy','-c:a','aac','-b:a','96k','-movflags','+faststart',str(final)])
 srt=out/(name+'.srt');vtt=out/(name+'.vtt');srt.write_text('\n\n'.join(f'{i+1}\n{stamp(a,True)} --> {stamp(b,True)}\n{t}' for i,(a,b,t) in enumerate(cues))+'\n');vtt.write_text('WEBVTT\n\n'+'\n\n'.join(f'{stamp(a)} --> {stamp(b)}\n{t}' for a,b,t in cues)+'\n');(out/(name+'_Guion.txt')).write_text('\n'.join(script)+'\n');Image.open(work/(jobs[0][1]['id']+'.png')).save(out/(name+'.jpg'),quality=90)
 info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-show_chapters','-of','json',str(final)],text=True));vs=next(s for s in info['streams'] if s['codec_type']=='video');au=next(s for s in info['streams'] if s['codec_type']=='audio');actual=float(info['format']['duration']);assert vs['codec_name']=='h264' and au['codec_name']=='aac' and abs(actual-elapsed)<1;assert len(info['chapters'])==len(cuts);assert final.stat().st_size<180_000_000;call(['ffmpeg','-hide_banner','-v','error','-i',str(final),'-f','null','-'])
 result={'id':audience,'title':'Administración de empresa' if audience=='admin' else 'Encuestadores y usuarios de lectura','file':final.name,'poster':name+'.jpg','subtitles':vtt.name,'srt':srt.name,'transcript':name+'_Guion.txt','duration_seconds':round(actual,3),'dimensions':[vs['width'],vs['height']],'bytes':final.stat().st_size,'sha256':hashlib.sha256(final.read_bytes()).hexdigest(),'chapters':cuts,'steps':steps,'voice':VOICE,'rate':RATE,'pitch':PITCH,'checks':{'h264_aac':True,'full_decode':True,'embedded_chapters':True,'caption_cues':len(cues),'illustrated_steps':len(steps)}}
 (out/(audience+'-video.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2));shutil.rmtree(work)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--folder',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--audience',choices=['admin','usuarios'],required=True);ap.add_argument('--preview',action='store_true');a=ap.parse_args();render(a.folder,a.out,a.audience,a.preview)
