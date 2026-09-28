"""Install only the exact reviewed Spanish training bundle; never access Supabase."""
from pathlib import Path,PurePosixPath
import argparse,hashlib,json,re,shutil,stat,subprocess,tempfile,zipfile
REPO='jaimehuang168/pulso-alto-parana-2026'
TAG='pulso-guia-visual-3.1.3-r2'
ARCHIVE='Pulso_Guia_Visual_R2_ES.zip'
SHA='9dc5384a3a2d880876e147d65b95eb7ef580ff32e21a5956df11777802774c6d'
RENDER='fbb9f2a657ec9e59fca4f3f9d9486105960d5fc8'
RUN=36418459043

def validate(archive):
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==SHA,'Unapproved package hash'
    with zipfile.ZipFile(archive) as z:
        infos=z.infolist();names=[i.filename for i in infos]
        assert len(names)==len(set(names)) and 170<=len(names)<=210,'Invalid entry list'
        assert sum(i.file_size for i in infos)<180000000,'Oversized content'
        for i in infos:
            p=PurePosixPath(i.filename)
            assert not p.is_absolute() and '..' not in p.parts and '\\' not in i.filename
            assert re.fullmatch(r'[A-Za-z0-9_./-]+',i.filename)
            assert not i.is_dir() and not stat.S_ISLNK(i.external_attr>>16)
            assert p.suffix in ['.json','.txt','.pdf','.html','.jpg','.png','.mp4','.vtt','.srt','.css','.js']
        manifest=json.loads(z.read('files.json'));assert manifest['schema']=='pulso-illustrated-files-1'
        assert set(manifest['files'])==set(names)-{'files.json'}
        for name,sha in manifest['files'].items():
            data=z.read(name);assert hashlib.sha256(data).hexdigest()==sha,name
            if PurePosixPath(name).suffix in ['.html','.txt','.json','.vtt','.srt','.css','.js']:
                assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail.com',data.decode()),name
        m=json.loads(z.read('tutorials.json'));course=json.loads(z.read('course-es.json'))
        assert m['build_commit']==RENDER and m['render_run']==RUN and m['edition']=='visual-r2'
        assert m['manual_steps']==147 and len(course['chapters'])==26
        assert len(m['videos'])==2 and sum(len(v['steps']) for v in m['videos'])==147
        assert len([n for n in names if n.startswith('images/paso_') and n.endswith('.jpg')])==147
        for v in m['videos']:
            assert v['voice']=='es-PY-TaniaNeural' and v['checks']['full_decode']
            assert hashlib.sha256(z.read(v['file'])).hexdigest()==v['sha256']
        assert json.loads(z.read('player-checks.json'))['failed']==0
        assert json.loads(z.read('document-checks.json'))['pass'] is True
        assert json.loads(z.read('illustrated-checks.json'))['pass'] is True
    return m

def install(archive,dest):
    m=validate(archive)
    assert not dest.exists(),'Destination must not already exist'
    dest.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pulso-verified-',dir=dest.parent) as tmp:
        staging=Path(tmp)/'content';staging.mkdir()
        with zipfile.ZipFile(archive) as z:z.extractall(staging)
        shutil.move(str(staging),str(dest))
    return m

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--archive',type=Path);ap.add_argument('--destination',type=Path);ap.add_argument('--validate-only',action='store_true');a=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='pulso-public-media-') as tmp:
        archive=a.archive
        if archive is None:
            subprocess.run(['gh','release','download',TAG,'--repo',REPO,'--pattern',ARCHIVE,'--dir',tmp],check=True)
            archive=Path(tmp)/ARCHIVE
        if a.validate_only:validate(archive)
        else:
            assert a.destination is not None
            install(archive,a.destination)
            # Existing App/manual links keep working. All paths remain inside the public site.
            web=a.destination.parent
            for target in [web/'v3/manual-es.html',web/'v3-demo/manual-es.html',web/'pruebas/ensayo/v3/manual-es.html']:
                if target.parent.is_dir():
                    import os
                    text=(a.destination/'manual.html').read_text()
                    for name in ['images/','Manual_Admin_ES.pdf','Manual_Usuarios_ES.pdf','Manual_Completo_ES.pdf','index.html']:
                        relative=os.path.relpath(a.destination/name,target.parent).replace(os.sep,'/')
                        if name.endswith('/'):relative+='/'
                        text=text.replace('"'+name,'"'+relative)
                    target.write_text(text)
    print('Verified 26 chapters, 147 illustrated steps, three PDFs and two narrated videos.')
