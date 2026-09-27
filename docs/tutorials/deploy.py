"""Attach a reviewed release asset to Pages, or run read-only published checks."""
from pathlib import Path
import argparse,json,os,re,subprocess,sys,tempfile
ap=argparse.ArgumentParser();ap.add_argument('--destination',type=Path);ap.add_argument('--verify-published',action='store_true');a=ap.parse_args();root=Path(__file__).resolve().parent;pin=json.loads((root/'release.lock.json').read_text())
assert pin['repository']=='jaimehuang168/pulso-alto-parana-2026'
assert re.fullmatch('pulso-tutorials-[0-9.]+',pin['tag'])
assert pin['archive']=='Pulso_313_Tutoriales_ES.zip'
assert re.fullmatch('[0-9a-f]{40}',pin['render_commit']) and re.fullmatch('[0-9a-f]{64}',pin['archive_sha256'])
if a.verify_published:
 assert not a.destination and re.fullmatch('[0-9a-f]{40}',os.environ.get('GITHUB_SHA',''))
 subprocess.run([sys.executable,str(root/'verify_published.py'),'--source-commit',os.environ['GITHUB_SHA'],'--render-commit',pin['render_commit'],'--render-run',str(pin['render_run']),'--out','evidence'],check=True)
else:
 assert a.destination is not None
 with tempfile.TemporaryDirectory(prefix='pulso-approved-tutorials-') as folder:
  subprocess.run(['gh','release','download',pin['tag'],'--repo',pin['repository'],'--pattern',pin['archive'],'--dir',folder],check=True)
  subprocess.run([sys.executable,str(root/'install_bundle.py'),str(Path(folder)/pin['archive']),str(a.destination),'--sha256',pin['archive_sha256'],'--render-commit',pin['render_commit'],'--render-run',str(pin['render_run'])],check=True)
