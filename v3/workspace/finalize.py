"""Finalize presentation changes without changing database or authorization logic."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'v3/web/app.mjs';s=p.read_text()
s=s.replace('Para crear otro administrador, el Super Admin usa Crear acceso.','Para otra cuenta administrativa, solicite un acceso nuevo a la administración de la plataforma.')
s=s.replace("S.offline=false;S.refreshError=false;if(!S.ui.paused)S.lastSync=new Date().toISOString();","S.offline=false;S.refreshError=false;")
s=s.replace("S.lastSync=S.dashboard?.server_time||S.lastSync;","S.lastSync=S.dashboard?.server_time||new Date().toISOString();")
s=s.replace("}}else S.dashboard=null;","}}else{S.dashboard=null;S.lastSync=new Date().toISOString();}")
s=s.replace("else{S.offline=!navigator.onLine;S.refreshError=true;if(force)error(e);}","else{S.offline=!navigator.onLine;S.refreshError=true;if(force)error(e);else{const b=document.querySelector('.topbar .badge');if(b){b.classList.add('warn');b.textContent='Actualización sin confirmar';}}}")
s=s.replace("S.page=page;S.error=null;S.choice=null;","S.page=page;S.error=null;S.choice=null;if(page!=='overview')S.ui.paused=false;")
s=s.replace("form('Crear acceso de coordinación / lectura','access-form'","form('Crear cuenta','access-form'")
p.write_text(s)
p=R/'v3/web/modules/views.mjs';s=p.read_text().replace('No es la contraseña de la cuenta ni una clave de Supabase.','Es distinta de la contraseña de su cuenta.')
p.write_text(s)
for file in ['v3/tests/company-browser.py']:
 p=R/file;s=p.read_text()
 s=s.replace("check('Rename admin persists with same code',page.get_by_text('ADMIN-DEMO · Administración DEMO corregida',exact=False).count()==1)","page.get_by_text('ADMIN-DEMO · Administración DEMO corregida',exact=False).wait_for(timeout=20000);check('Rename admin persists with same code',page.get_by_text('ADMIN-DEMO · Administración DEMO corregida',exact=False).count()==1)")
 s=s.replace("check('Personnel correction succeeds through SQL',page.get_by_text('Encuestador DEMO corregido',exact=False).count()>0)","page.get_by_text('Encuestador DEMO corregido',exact=False).wait_for(timeout=20000);check('Personnel correction succeeds through SQL',page.get_by_text('Encuestador DEMO corregido',exact=False).count()>0)")
 p.write_text(s)
# Bilingual documents are prepared privately outside the repository; old current-tree sources are removed.
for name in ['v3/web/manual-es-zh.html','docs/company-manual-sections.json','docs/owner_only_access.py','docs/direct_use_policy.py']:
 (R/name).unlink(missing_ok=True)
# The public build never produces or includes a bilingual manual.
(R/'docs/build-company-manuals.py').write_text("from pathlib import Path\nimport runpy\nrunpy.run_path(str(Path(__file__).with_name('workspace-manual.py')),run_name='__main__')\n")
p=R/'AGENTS.md';s=p.read_text();s+='\n## Interfaz y documentación 3.1.3\n\n- Keep the application and its public manual entirely in Spanish.\n- Keep bilingual owner manuals outside the public repository, build artifacts and Pages.\n- Present five work areas without owner-role banners; authorization remains server-side.\n- Do not reset local survey storage or reintroduce activation. This UI release has no new SQL migration.\n';p.write_text(s)
print('Presentation finalized. Existing Auth, field capture validation, SQL and encrypted vault retained.')
