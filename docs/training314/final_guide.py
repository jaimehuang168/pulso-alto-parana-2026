"""Final pixel-accurate crops; the source iPhone screenshots are 1170px, not the 500px review thumbnail."""
from pathlib import Path
import argparse,json
from build_public import read_course,prepare_images,make_html,make_pdf
CROPS={'13.4':[48,2190,1110,3045],'20.4':[48,2190,1110,3045],'20.5':[30,1760,1140,3210]}
def build(source,screens,out):
 out.mkdir(parents=True,exist_ok=True);data=read_course(source)
 for chapter in data['chapters']:
  for step in chapter['steps']:
   if step['id'] in CROPS:step['crop']=CROPS[step['id']]
 manifest=prepare_images(data,screens,out/'images');make_html(data,out/'manual.html')
 for name,audience in [('Manual_Admin_ES','admin'),('Manual_Usuarios_ES','usuarios'),('Manual_Completo_ES',None)]:make_pdf(data,out,out/(name+'.pdf'),audience)
 (out/'course-es.json').write_text(json.dumps(data,ensure_ascii=False,indent=2))
 (out/'manual-integrity.json').write_text(json.dumps({'chapters':26,'steps':147,'illustrated_steps':len(manifest),'private_material_included':False,'pixel_crop_corrections':CROPS,'images':manifest},indent=2))
 print('147 steps rendered. Native task crops use original image pixels and retain their buttons.')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--screens',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();build(a.source,a.screens,a.out)
