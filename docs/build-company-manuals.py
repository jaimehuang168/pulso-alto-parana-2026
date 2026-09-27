"""Build the public Spanish manual and link the separately reviewed video guides."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).with_name('workspace-manual.py')),run_name='__main__')
manual=Path(__file__).resolve().parents[1]/'v3/web/manual-es.html'
text=manual.read_text(encoding='utf-8')
marker='<nav id="indice">'
assert text.count(marker)==1,'Manual index structure changed; review before publishing'
link='<section aria-label="Tutoriales en video"><h2>Aprender con videos</h2><p>Guías en español para administración de empresa, encuestadores y usuarios de lectura. Narración, subtítulos y capítulos con datos ficticios.</p><p><a href="https://jaimehuang168.github.io/pulso-alto-parana-2026/tutoriales/">Ver tutoriales en video</a></p></section>'
manual.write_text(text.replace(marker,link+marker,1),encoding='utf-8')
