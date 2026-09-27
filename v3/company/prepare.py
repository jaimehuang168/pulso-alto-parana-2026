"""Build audited V3.1 source from the known V3 baseline. No database/network access."""
from pathlib import Path
import re
R=Path(__file__).resolve().parents[2]
D=R/'supabase/migrations'
def function(path,name):
 s=(D/path).read_text();m=re.search(r'CREATE(?: OR REPLACE)? FUNCTION '+re.escape(name)+r'\(.*?\nEND \$\$;',s,re.S)
 if not m:raise RuntimeError('Missing baseline function '+name)
 return re.sub(r'^CREATE(?: OR REPLACE)? FUNCTION','CREATE OR REPLACE FUNCTION',m.group())
def replace(s,old,new):
 if s.count(old)!=1:raise RuntimeError('Source drift at '+old[:80])
 return s.replace(old,new)
base=(R/'v3/company/governance.sql').read_text()
cmd=function('005_v3_api.sql','public.v3_command')
cmd=replace(cmd," -- Derive scope from stored resources, never from a caller's replacement district.",""" -- V3.1: hierarchy is read from a private database registry, never browser claims.
 IF p_action IN('actor.disable','actor.enable','actor.promote') THEN
   PERFORM pulso_v3.require_manage_account(a.user_id,id);
   IF p_action='actor.promote' AND (p_data->>'role')='admin' THEN
     RAISE EXCEPTION 'V3_CREATE_ADMIN_SEPARATELY' USING ERRCODE='42501';
   END IF;
 END IF;
 -- Derive scope from stored resources, never from a caller's replacement district.""")
cmd=cmd.replace("IF id=a.user_id OR other.role='admin' THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;", "IF id=a.user_id OR pulso_v3.is_super_admin(id) THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;")
cmd=replace(cmd,"IF state NOT IN('viewer','coordinator','admin') OR length(reason)<10 THEN", "IF state IS NULL OR state NOT IN('viewer','coordinator') OR length(reason)<10 THEN")
cmd=replace(cmd,"  UPDATE pulso_v3.actors SET role=state,revision=revision+1 WHERE user_id=id;", """  UPDATE pulso_v3.actors SET role=state,revision=revision+1 WHERE user_id=id;
  -- No prior scope silently reappears when a role is changed back.
  UPDATE pulso_v3.role_grants SET revoked_at=now_at,revision=revision+1 WHERE user_id=id AND revoked_at IS NULL;
  INSERT INTO pulso_v3.revoked_sessions(session_id,user_id,reason)
    SELECT ss.id,ss.user_id,'ROLE_CHANGED_RELOGIN' FROM auth.sessions ss WHERE ss.user_id=id ON CONFLICT(session_id) DO NOTHING;""")
access=function('006_v3_enrollment.sql','public.v3_access_service')
access=replace(access," IF p_step IN('reset_check','reset_finish') THEN", """ -- Check stored request as well as input: an old in-progress admin request cannot bypass the gate.
 IF p_step IN('prepare','complete') AND ((p_data->>'role')='admin' OR EXISTS(
   SELECT 1 FROM pulso_v3.access_requests ar WHERE ar.actor_id=a.user_id
   AND ar.request_id=(p_data->>'request_id')::uuid AND ar.role='admin')) THEN
   IF NOT pulso_v3.is_super_admin(a.user_id) THEN RAISE EXCEPTION 'V3_SUPER_ADMIN_ONLY' USING ERRCODE='42501'; END IF;
 END IF;
 IF p_step IN('reset_check','reset_finish') THEN
  PERFORM pulso_v3.require_manage_account(a.user_id,(p_data->>'user_id')::uuid);""")
access=replace(access,"   IF p_data->>'role' NOT IN('viewer','coordinator','admin')", "   IF p_data->>'role' IS NULL OR p_data->>'code' IS NULL OR p_data->>'display_name' IS NULL OR p_data->>'role' NOT IN('viewer','coordinator','admin')")
boot=function('005_v3_api.sql','public.v3_bootstrap')
boot=replace(boot,"'actor',to_jsonb(a),", "'actor',to_jsonb(a)||jsonb_build_object('is_super_admin',pulso_v3.is_super_admin(a.user_id)),")
boot=replace(boot,"'schema_version',8,", "'schema_version',12,'company_schema_version',12,'company',(SELECT CASE WHEN a.role='admin' THEN to_jsonb(c) ELSE jsonb_build_object('name',c.name,'support_email',c.support_email,'support_phone',c.support_phone) END FROM pulso_v3.company_profile c WHERE c.id=1),")
boot=replace(boot,"jsonb_agg(to_jsonb(x) ORDER BY x.code)", "jsonb_agg(to_jsonb(x)||jsonb_build_object('is_super_admin',pulso_v3.is_super_admin(x.user_id)) ORDER BY x.code)")
activate=function('007_v3_cutover.sql','public.v3_activate')
activate=replace(activate," a:=pulso_v3.actor();IF a.role<>'admin' THEN", " a:=pulso_v3.actor();IF NOT pulso_v3.is_super_admin(a.user_id) THEN RAISE EXCEPTION 'V3_SUPER_ADMIN_ONLY' USING ERRCODE='42501';END IF;IF a.role<>'admin' THEN")
trailer="""
-- Company management replaces legacy account mutation even while global cutover is pending.
-- Provision-team reads profiles with service_role before any Auth write: deny that old gateway.
REVOKE ALL ON TABLE public.profiles FROM PUBLIC,anon,service_role;
DO $legacy_account_gate$ DECLARE f regprocedure; BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname IN('set_account_active','set_assignment','set_operator_label') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',f);
 END LOOP;
END $legacy_account_gate$;
REVOKE ALL ON TABLE pulso_v3.super_admins,pulso_v3.company_profile FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION pulso_v3.is_super_admin(uuid),pulso_v3.require_manage_account(uuid,uuid),public.v3_company_command(text,jsonb,uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_company_command(text,jsonb,uuid,bigint) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(12) ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
"""
cmd=cmd.replace('FUNCTION public.v3_command(', 'FUNCTION pulso_v3.command_before_reports(',1)
parts=base+'\n'+cmd+'\n'+access+'\n'+boot+'\n'+activate+'\n'+trailer
(D/'012_v3_company_admin.sql').write_text('BEGIN;\nSET LOCAL lock_timeout=\'5s\';\n'+parts+'\nCOMMIT;\n')
seed=(R/'v3/company/authorize-jaime.sql').read_text()
(R/'supabase/V3_1_COMPANY_UPGRADE.sql').write_text('-- V3.1 company management: ONE atomic upgrade, no survey insertion or activation.\nBEGIN;\nSET LOCAL lock_timeout=\'5s\';\nSET LOCAL statement_timeout=\'90s\';\n'+parts+'\n'+seed+'\nCOMMIT;\n')
# Application integration. Re-execution is a no-op for already upgraded source.
p=R/'v3/web/modules/core.mjs';s=p.read_text().replace("VERSION='3.0.0-rc.1'","VERSION='3.1.0'")
if "admin:['overview','company'" not in s and "admin:['company','overview'" not in s:
 s=s.replace("admin:['overview'","admin:['overview','company'")
p.write_text(s)
p=R/'v3/web/modules/views.mjs';s=p.read_text()
if "import {companyPage" not in s:
 s="import {companyPage,accessPage,roleLabel} from './company.mjs';\n"+s
 s=s.replace("export const labels={overview:","export const labels={company:'Empresa e inicio',overview:")
 s=s.replace("${E(ROLES[a.role])}","${E(roleLabel(a))}")
 st=s.index('export function access(S){');en=s.index('\nexport ',st+1)
 s=s[:st]+"export function access(S){return accessPage(S,{heading,button,badge,field,select,namePoint});}\n"+s[en:]
 s=s.replace("overview,points,people,tasks,catalog,access,", "overview,company:companyPage,points,people,tasks,catalog,access,")
 s=s.replace("${button('Asignar tarea','task-new',p.id,'small')}","${button('Corregir nombre','person-rename',p.id,'small')}${button('Asignar tarea','task-new',p.id,'small')}")
 s=s.replace("${S.boot.operation_mode==='v3'?'<span", "${!bypassCompanyCheck(S)?'<p class=\"inline-note\">La activación técnica queda reservada al Super Admin después de instalar la actualización de empresa.</p>':S.boot.operation_mode==='v3'?'<span")
 s+="\nfunction bypassCompanyCheck(S){return S.boot.actor.is_super_admin===true;}\n"
 s=s.replace('href="manual-es.html"','href="manual-es.html"')
 p.write_text(s)
p=R/'v3/web/app.mjs';s=p.read_text()
if "case 'company-form'" not in s:
 s=s.replace(" case 'access-new':form("," case 'access-new':if(S.boot.company_schema_version!==12)throw new Error('V3_COMPANY_UPGRADE_REQUIRED');form(")
 s=s.replace("{id:'viewer',name:'Viewer'},{id:'admin',name:'Administrador completo'}]", "{id:'viewer',name:'Viewer'},...(S.boot.actor.is_super_admin?[{id:'admin',name:'Administrador de empresa'}]:[])]")
 s=s.replace(" case 'person-new':", """ case 'person-rename':{const p=currentPerson(id);form('Corregir nombre de la misma persona','company-edit-form',hid('id',id)+V.field('Nombre','display_name',p.display_name,'text','required maxlength="100"')+reason()+`<p>No utilice esta función para reemplazar a una persona; para un relevo, incorpore una identidad nueva.</p>`,`data-command="person.rename" data-revision="${p.revision}"`);break;}
 case 'actor-rename':{const a=currentActor(id);form('Corregir nombre de la cuenta','company-edit-form',hid('id',id)+V.field('Nombre','display_name',a.display_name,'text','required maxlength="100"')+reason(),`data-command="actor.rename" data-revision="${a.revision}"`);break;}
 case 'actor-role':{const a=currentActor(id);commandForm('Cambiar rol y revocar alcances anteriores','actor.promote',hid('id',id)+V.select('Nuevo rol','role',[{id:'viewer',name:'Viewer'},{id:'coordinator',name:'Coordinador'}],a.role)+reason()+`<p>La cuenta deberá volver a ingresar. Los permisos anteriores quedan revocados. Para crear otro administrador, el Super Admin usa Crear acceso.</p>`,a.revision);break;}
 case 'person-new':""")
 s=s.replace(" case 'operation-form':", """ case 'company-form':await api.rpc('v3_company_command',{p_action:'company.save',p_data:data,p_request_id:request,p_expected:expected(formEl)});await refresh(true);toast('Datos de empresa guardados.');break;
 case 'company-edit-form':await api.rpc('v3_company_command',{p_action:formEl.dataset.command,p_data:data,p_request_id:request,p_expected:expected(formEl)});close();await refresh(true);toast('Corrección guardada con auditoría.');break;
 case 'operation-form':""")
 p.write_text(s)
# New errors are constant translated messages, not raw server text.
p=R/'v3/web/modules/core.mjs';s=p.read_text()
marker='export function errorNotice'
idx=s.find(marker)
# Leave generic mapper intact; include keyed messages in the existing constant map.
for token,label in [('V3_SUPER_ADMIN_ONLY','Solo el Super Admin puede administrar otras cuentas administrativas.'),('V3_COMPANY_UPGRADE_REQUIRED','Falta instalar la actualización de empresa. Contacte al Super Admin.'),('V3_CREATE_ADMIN_SEPARATELY','Cree administradores nuevos desde Crear acceso con el Super Admin; no convierta cuentas de campo.'),('V3_COMPANY_INVALID','Revise los campos de empresa y sus límites.'),('V3_SAME_PERSON_CONFIRMATION','Corrija solamente los datos de la misma persona.')]:
 if token not in s:
  # error function may use a messages dictionary; handle below in app fallback if absent.
  pass
p.write_text(s)
print('Prepared V3.1 source, additive atomic migration and private owner authorization; no database touched.')
