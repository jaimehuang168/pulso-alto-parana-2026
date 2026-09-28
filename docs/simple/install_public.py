"""Install exactly approved Spanish media and explicit old-flow notices."""
from pathlib import Path,PurePosixPath
import argparse,hashlib,json,re,stat,subprocess,tempfile,zipfile,os
ROOT=Path(__file__).resolve().parents[2]
def install(archive,web,lock):
 assert hashlib.sha256(archive.read_bytes()).hexdigest()==lock['sha256'],'Unapproved media package'
 dest=web/'ingreso';assert not dest.exists(),'Destination already exists'
 with zipfile.ZipFile(archive) as z:
  infos=z.infolist();names=[i.filename for i in infos];assert len(names)==len(set(names)) and len(names)<100 and sum(i.file_size for i in infos)<90000000
  for i in infos:
   p=PurePosixPath(i.filename);assert not p.is_absolute() and '..' not in p.parts and '\\' not in i.filename
   assert not i.is_dir() and not stat.S_ISLNK(i.external_attr>>16) and re.fullmatch('[A-Za-z0-9_./-]+',i.filename)
  manifest=json.loads(z.read('files.json'));assert manifest['edition']=='personal-phone-015';assert set(manifest['files'])==set(names)-{'files.json'}
  for name,sha in manifest['files'].items():
   data=z.read(name);assert hashlib.sha256(data).hexdigest()==sha,name
   if PurePosixPath(name).suffix in ['.html','.txt','.json','.js','.css','.vtt','.srt']:assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail.com',data.decode()),name
  assert json.loads(z.read('document-checks.json'))['steps']==22 and json.loads(z.read('player-checks.json'))['failed']==0
  dest.mkdir(parents=True);z.extractall(dest)
 for folder in ['v3','v3-demo','pruebas/ensayo/v3']:
  target=web/folder
  if not target.is_dir():continue
  prefix=os.path.relpath(dest,target).replace(os.sep,'/')+'/'
  text=(dest/'index.html').read_text()
  for name in ['images/','Guia_Ingreso_Personal_ES.pdf','videos.html']:text=text.replace('"'+name,'"'+prefix+name)
  (target/'manual-simple.html').write_text(text)
  old=target/'manual-es.html'
  if old.exists():
   note='<aside data-personal-notice style="padding:22px;background:#fff3d5;border-left:5px solid #a47216"><strong>Actualización: ingreso con teléfono personal.</strong> Para cuentas nuevas, la empresa crea código, contraseña y lugar. Ya no se pide QR, segunda frase local ni inicio manual de tarea. <a href="manual-simple.html">Siga primero la guía actualizada con imágenes y videos</a>. El manual completo conserva las explicaciones del flujo anterior para archivos y cuentas antiguas; no repita esos pasos en una cuenta nueva.</aside>'
   original=old.read_text();assert '<main>' in original;old.write_text(original.replace('<main>','<main>'+note,1))
 for name in ['index.html','manual.html']:
  p=web/'tutoriales'/name
  if p.exists():
   note='<aside data-personal-notice style="margin:20px;padding:22px;background:#fff3d5;color:#143e47;border-left:5px solid #a47216"><strong>Nuevo: ingreso con su propio teléfono.</strong> <a href="../ingreso/videos.html">Ver Admin y Encuestador: código, contraseña y encuesta directa</a>. Las explicaciones anteriores de QR, frase local adicional e inicio manual corresponden al flujo anterior. Para cuentas nuevas, siga la guía de ingreso personal. Los controles de apertura, consentimiento y permisos se mantienen.</aside>'
   text=p.read_text();assert '<main>' in text;p.write_text(text.replace('<main>','<main>'+note,1))
 # Original video files are unchanged; the two public HTML entries have a reviewed notice.
 p=web/'tutoriales/files.json'
 if p.exists():
  old=json.loads(p.read_text());old['overlay']='personal-phone-015';old['overlay_bundle_sha256']=lock['sha256']
  for name in ['index.html','manual.html']:old['files'][name]=hashlib.sha256((p.parent/name).read_bytes()).hexdigest()
  p.write_text(json.dumps(old,indent=2))
 print('Approved personal guide installed; previous instructions explicitly marked.')
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--web',type=Path,default=ROOT/'web');ap.add_argument('--archive',type=Path);a=ap.parse_args();lock=json.loads((ROOT/'docs/simple/release.json').read_text())
 with tempfile.TemporaryDirectory() as t:
  p=a.archive
  if p is None:
   subprocess.run(['gh','release','download',lock['tag'],'--repo','jaimehuang168/pulso-alto-parana-2026','--pattern',lock['asset'],'--dir',t],check=True);p=Path(t)/lock['asset']
  install(p,a.web,lock)
