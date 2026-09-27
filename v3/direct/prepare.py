"""Reviewed source transforms; never connects to a database or changes hosted settings."""
from pathlib import Path
import json
R=Path(__file__).resolve().parents[2]
p=R/'v3/web/app.mjs';s=p.read_text()
start=s.find(" case 'activate':await navigate('company');break;")
end=s.find(" case 'password':",start)
if start>=0:
 assert end>start
 s=s[:start]+" case 'readiness-refresh':await loadReadiness();render();break;\n"+s[end:]
start=s.find(" case 'company-readiness-form':{")
end=s.find(" case 'company-form':",start)
if start>=0:
 assert end>start
 s=s[:start]+s[end:]
s=s.replace("import {isCompanyAdmin} from './modules/company-readiness.mjs';\n",'')
s=s.replace("S.readiness=await api.rpc('v3_company_readiness')","S.readiness=await api.rpc('v3_installation_status')")
s=s.replace('Módulo 013 pendiente de instalación. La empresa puede continuar preparando datos y usuarios.','Estado de acceso directo no disponible. Solo el Super Admin revisa la instalación; la empresa puede preparar datos y usuarios.')
p.write_text(s)
p=R/'v3/web/modules/views.mjs';s=p.read_text()
s=s.replace('<strong>Preparación de V3 — no activado.</strong> La base V2 no se modifica desde esta pantalla. La activación técnica requiere evidencia y un cambio controlado.','<strong>Configuración disponible.</strong> El Super Admin completa la actualización técnica. Puede preparar datos y usuarios sin un formulario de activación.')
s=s.replace("button('Preflight de migración','preflight')","(S.boot.actor.is_super_admin?button('Estado técnico','preflight'):'')")
start=s.find('<section class="card"><h2>Confirmaciones de la empresa</h2>')
if start>=0:
 end=s.index('</section>',start)+len('</section>')
 s=s[:start]+'<section class="card"><h2>Acceso directo</h2><p>La empresa utiliza sus funciones después de ingresar. La recepción y la difusión se administran por separado.</p></section>'+s[end:]
p.write_text(s)
p=R/'v3/web/modules/company.mjs';s=p.read_text().replace('La preparación, la activación técnica, la recepción de entrevistas y la difusión son cuatro decisiones distintas.','Prepare los datos al ingresar. Abra la recepción y autorice la difusión solamente cuando corresponda; no hay un paso de activación de versión.').replace('El responsable técnico debe instalar V3_1_COMPANY_UPGRADE.sql una sola vez.','Solo el Super Admin revisa la instalación técnica.')
p.write_text(s)
p=R/'v3/scripts/build.mjs';s=p.read_text().replace("build:'3.1.1'","build:'3.1.2'").replace("version:'3.1.1'","version:'3.1.2'")
anchor="sql+=`UPDATE pulso_v3.questionnaires SET items="
if "'014_v3_direct_use.sql'" not in s:
 assert anchor in s
 s=s.replace(anchor,"sql+=await fs.readFile(path.join(repo,'supabase/migrations','014_v3_direct_use.sql'),'utf8')+'\\n';\n "+anchor)
p.write_text(s)
p=R/'v3/web/simulation.mjs';s=p.read_text()
s='\n'.join(line for line in s.split('\n') if "user=companyAdmin;session=companySession;await call('v3_company_readiness_save'" not in line)
s=s.replace("},1);\n for(const [idx,d]", "},2);\n for(const [idx,d]")
p.write_text(s)
base13=(R/'supabase/migrations/013_v3_company_handoff.sql').read_text().strip()
assert base13.startswith('BEGIN;') and base13.endswith('COMMIT;')
base13=base13[len('BEGIN;'): -len('COMMIT;')]
base14=(R/'supabase/migrations/014_v3_direct_use.sql').read_text();start=base14.index('BEGIN;');body14=base14[start+len('BEGIN;'):].strip();assert body14.endswith('COMMIT;');body14=body14[:-len('COMMIT;')]
prefix="""-- Only the designated Super Admin uses Supabase SQL Editor. Complete file, once.
-- Checks 013 automatically. Existing 004-012 data, identities and answers are preserved.
-- Switches the technical API to V3 and closes V2 endpoints. No company Activate step.
-- Does NOT confirm old-device outboxes, perform a backup, certify phones, change the
-- fieldwork date, open points or authorize publication. Offline V2 queues are not erased
-- and are NOT migrated automatically; preserve any such queue for separate recovery.
BEGIN;
SET LOCAL lock_timeout='5s';SET LOCAL statement_timeout='90s';
DO $owner$
DECLARE u uuid;n integer;before13 boolean;
BEGIN
 IF to_regprocedure('pulso_v3.is_super_admin(uuid)') IS NULL THEN RAISE EXCEPTION 'V3_INSTALL_012_FIRST';END IF;
 SELECT count(*),(array_agg(id))[1] INTO n,u FROM auth.users WHERE lower(email)='jaimehuang168@gmail.com' AND email_confirmed_at IS NOT NULL;
 IF n<>1 OR NOT pulso_v3.is_super_admin(u) OR NOT EXISTS(SELECT 1 FROM pulso_v3.actors WHERE user_id=u AND role='admin' AND active AND enrolled)
 THEN RAISE EXCEPTION 'V3_DESIGNATED_OWNER_REQUIRED';END IF;
 before13:=EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=13);
 PERFORM set_config('pulso.module_013_before',before13::text,true);
 IF NOT before13 THEN
"""
combined=prefix+" EXECUTE $module013$"+base13+"$module013$;\n END IF;\nEND $owner$;\n"+body14+"""
SELECT current_setting('pulso.module_013_before')::boolean AS module_013_before,
 EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=13) AS module_013_after,
 EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=14) AS direct_use_installed,
 (SELECT operation_mode FROM public.settings WHERE id=1) AS operation_mode,
 false AS activation_required,
 (SELECT phase FROM pulso_v3.operations WHERE id=1) AS fieldwork_phase,
 (SELECT fieldwork_date FROM pulso_v3.operations WHERE id=1) AS fieldwork_date;
COMMIT;
"""
(R/'supabase/V3_1_DIRECT_USE.sql').write_text(combined)
print('Prepared direct-use UI, compatible owner installer and unchanged survey controls.')
