-- V3.1 direct use. Platform installation only; never called by the browser.
-- Retires the separate activation/attestation step. Does not open fieldwork.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $direct$
DECLARE mode text; r record; changed boolean:=false;
BEGIN
 IF to_regprocedure('pulso_v3.is_super_admin(uuid)') IS NULL OR
    (SELECT count(*) FROM pulso_v3.schema_versions WHERE version BETWEEN 4 AND 13)<>10
 THEN RAISE EXCEPTION 'V3_DIRECT_BASELINE_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pulso_v3.actors a JOIN pulso_v3.super_admins s ON s.user_id=a.user_id
   JOIN auth.users u ON u.id=a.user_id WHERE a.role='admin' AND a.active AND a.enrolled AND u.email_confirmed_at IS NOT NULL)
 THEN RAISE EXCEPTION 'V3_DIRECT_OWNER_REQUIRED'; END IF;
 PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'V3_DIRECT_SETTINGS_MISSING';END IF;
 SELECT operation_mode INTO mode FROM public.settings WHERE id=1 FOR UPDATE;
 IF mode IS NULL OR mode NOT IN('v2','v3') THEN RAISE EXCEPTION 'V3_DIRECT_SETTINGS_MISSING';END IF;
 -- Fence old writers while the last V2 checks and permission revocations run.
 LOCK TABLE public.profiles,public.responses IN ACCESS EXCLUSIVE MODE;
 IF mode='v2' THEN
  IF EXISTS(SELECT 1 FROM public.profiles p LEFT JOIN pulso_v3.actors a ON a.user_id=p.id
    WHERE a.user_id IS NULL OR a.active IS DISTINCT FROM p.active OR a.role IS DISTINCT FROM p.role)
  THEN RAISE EXCEPTION 'V3_LEGACY_ACTOR_DRIFT';END IF;
  IF EXISTS(SELECT 1 FROM public.responses) OR EXISTS(SELECT 1 FROM pulso_v3.responses) OR
     NOT EXISTS(SELECT 1 FROM public.settings WHERE id=1 AND state='setup') OR
     NOT EXISTS(SELECT 1 FROM pulso_v3.operations WHERE id=1 AND phase='setup')
  THEN RAISE EXCEPTION 'V3_DIRECT_LEGACY_DATA_NEEDS_REVIEW';END IF;
  changed:=true;
 END IF;
 -- Preserve old implementations and records; close only the superseded API.
 FOR r IN SELECT p.oid::regprocedure sig,pg_get_functiondef(p.oid) def,p.proowner owner_id
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN(
   'bootstrap','ping','my_activity','submit_response','submit_response_v2','void_response','get_dashboard','get_dashboard_v2','get_records','get_records_v2',
   'list_accounts','list_accounts_v2','save_settings','save_catalog','set_fieldwork_state','set_assignment','set_account_active','set_viewer_access','set_operator_label','log_export') LOOP
  INSERT INTO pulso_v3.legacy_function_backups(signature,definition,original_oid,owner_name)
   VALUES(r.sig::text,r.def,r.sig::oid,pg_get_userbyid(r.owner_id)) ON CONFLICT(signature) DO NOTHING;
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',r.sig);
 END LOOP;
 REVOKE ALL ON TABLE public.districts,public.settings,public.candidates,public.stations,public.profiles,
   public.responses,public.audit_log,public.district_signals FROM PUBLIC,anon,authenticated,service_role;
 IF changed THEN
  UPDATE public.settings SET operation_mode='v3' WHERE id=1;
  UPDATE pulso_v3.operations SET cutover_at=clock_timestamp(),revision=revision+1 WHERE id=1;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=14) THEN
  PERFORM pulso_v3.log(NULL,'deployment.direct_use_installed',NULL,NULL,jsonb_build_object(
   'database_role',session_user,'previous_mode',mode,'company_activation_required',false,
   'basis','Owner requested direct V3.1 use without an activation step',
   'backup_or_device_acceptance_attested',false,'fieldwork_changed',false));
 END IF;
 -- No backup_verified_at, company declarations or acceptance timestamps are invented.
END $direct$;
CREATE OR REPLACE FUNCTION public.v3_installation_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; BEGIN
 a:=pulso_v3.actor();
 RETURN jsonb_build_object('app_version','3.1.2','operation_mode',(SELECT operation_mode FROM public.settings WHERE id=1),
  'module_013_installed',EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=13)
    AND to_regprocedure('public.v3_company_readiness()') IS NOT NULL
    AND to_regclass('pulso_v3.company_readiness') IS NOT NULL,
  'module_014_installed',EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=14),
  'activation_required',false,'fieldwork_phase',(SELECT phase FROM pulso_v3.operations WHERE id=1));
END $$;
-- A stale browser must not reopen the retired approval workflow.
REVOKE ALL ON FUNCTION public.v3_activate(boolean,text,text),public.v3_company_activate(bigint,uuid),
 public.v3_company_readiness_save(boolean,text,text,bigint,uuid) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.v3_installation_status() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.v3_installation_status() TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(14) ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
