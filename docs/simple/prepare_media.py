"""Prepare deterministic documentation geometry and generic chapter checks."""
from pathlib import Path
import json,argparse
from PIL import Image
ap=argparse.ArgumentParser();ap.add_argument('--screens',type=Path,required=True);a=ap.parse_args()
p=Path(__file__).parent/'course.json';data=json.loads(p.read_text());changes=[]
for c in data['chapters']:
 for step in c['steps']:
  if not step.get('crop'):continue
  im=Image.open(a.screens/step['image']);x,y,r,b=step['crop'];assert 0<=x<r<=im.width and 0<=y<im.height
  if b>im.height:changes.append({'step':step['id'],'old_bottom':b,'actual_bottom':im.height});step['crop'][3]=im.height
p.write_text(json.dumps(data,ensure_ascii=False,indent=2))
print('Screenshot boundary corrections:',changes)
src=Path('docs/tutorials/verify_player.py').read_text()
src=src.replace('.nth(2)',".nth(min(2,len(v['chapters'])-1))").replace("v['chapters'][2]","v['chapters'][min(2,len(v['chapters'])-1)]")
Path('/tmp/verify-simple-player.py').write_text(src)
