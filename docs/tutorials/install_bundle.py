"""Install an exactly approved, hash-pinned public teaching bundle. No database access."""
from pathlib import Path
import argparse,hashlib,json,re,stat,zipfile
ap=argparse.ArgumentParser();ap.add_argument('archive',type=Path);ap.add_argument('destination',type=Path);ap.add_argument('--sha256',required=True);ap.add_argument('--render-commit',required=True);ap.add_argument('--render-run',required=True);a=ap.parse_args()
assert re.fullmatch('[0-9a-f]{64}',a.sha256),'Missing approved ZIP hash'
assert hashlib.sha256(a.archive.read_bytes()).hexdigest()==a.sha256,'ZIP content changed'
with zipfile.ZipFile(a.archive) as z:
 entries=z.infolist();names=[f.filename for f in entries];assert len(names)==len(set(names)) and len(names)<40
 assert sum(f.file_size for f in entries)<210_000_000,'Oversized teaching bundle'
 for f in entries:
  assert re.fullmatch('[A-Za-z0-9_.-]+',f.filename) and not f.is_dir(),'Unexpected directory or path'
  assert not stat.S_ISLNK(f.external_attr>>16),'Symlink rejected'
 data=json.loads(z.read('tutorials.json'));checks=json.loads(z.read('player-checks.json'))
 assert data['version']=='3.1.3' and data['language']=='es' and len(data['videos'])==2
 assert data['build_commit']==a.render_commit and str(data['render_run'])==a.render_run,'Wrong approved render'
 assert checks['failed']==0 and checks['passed']>=20
 assert set(names)==set(data['files'])|{'tutorials.json'},'Unmanifested files'
 for name,digest in data['files'].items():assert hashlib.sha256(z.read(name)).hexdigest()==digest,'Hash mismatch: '+name
 assert sum(len(v['chapters']) for v in data['videos'])==32
 for v in data['videos']:
  assert v['checks']['h264_aac'] and v['checks']['full_decode'] and v['checks']['embedded_chapters']
  assert hashlib.sha256(z.read(v['file'])).hexdigest()==v['sha256']
  assert len(z.read(v['file']))==v['bytes'] and 10<v['duration_seconds']<1200
  text=z.read(v['transcript']).decode('utf-8');assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',text)
 a.destination.mkdir(parents=True,exist_ok=True)
 assert not any(a.destination.iterdir()),'Destination must be empty; do not overwrite unrelated files'
 for f in entries:(a.destination/f.filename).write_bytes(z.read(f))
 print(json.dumps({'installed':'tutoriales','version':data['version'],'render_run':data['render_run'],'zip_sha256':a.sha256,'videos':[{'id':v['id'],'seconds':v['duration_seconds'],'bytes':v['bytes']} for v in data['videos']},indent=2))
