-- Only the designated Super Admin uses Supabase SQL Editor. Complete file, once.
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
 EXECUTE $module013$
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $$ BEGIN
 IF to_regprocedure('pulso_v3.is_super_admin(uuid)') IS NULL OR
    NOT EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=12)
 THEN RAISE EXCEPTION 'V3_COMPANY_BASELINE_REQUIRED'; END IF;
END $$;
CREATE TABLE IF NOT EXISTS pulso_v3.company_readiness(
 id integer PRIMARY KEY CHECK(id=1), outbox_handled boolean NOT NULL DEFAULT false,
 backup_reference text NOT NULL DEFAULT '' CHECK(length(backup_reference)<=2000),
 acceptance_reference text NOT NULL DEFAULT '' CHECK(length(acceptance_reference)<=2000),
 revision bigint NOT NULL DEFAULT 1, updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
 activated_at timestamptz, activated_by uuid REFERENCES auth.users(id)
);
ALTER TABLE pulso_v3.company_readiness ENABLE ROW LEVEL SECURITY;
INSERT INTO pulso_v3.company_readiness(id) VALUES(1) ON CONFLICT(id) DO NOTHING;
REVOKE ALL ON TABLE pulso_v3.company_readiness FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION pulso_v3.require_company_operator() RETURNS pulso_v3.actors
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; BEGIN
 a:=pulso_v3.actor();
 IF a.role<>'admin' OR pulso_v3.is_super_admin(a.user_id) THEN
  RAISE EXCEPTION 'V3_COMPANY_ADMIN_ONLY' USING ERRCODE='42501';
 END IF;
 RETURN a;
END $$;
CREATE OR REPLACE FUNCTION public.v3_company_readiness() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;c pulso_v3.company_readiness;can_edit boolean;mode text;
BEGIN
 a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 SELECT * INTO c FROM pulso_v3.company_readiness WHERE id=1;
 SELECT operation_mode INTO mode FROM public.settings WHERE id=1;
 can_edit:=NOT pulso_v3.is_super_admin(a.user_id) AND mode='v2';
 RETURN jsonb_build_object('schema_version',13,'responsibility','company_admin','operation_mode',mode,
  'can_edit',can_edit,'revision',c.revision,'outbox_handled',c.outbox_handled,
  'backup_recorded',length(btrim(c.backup_reference))>=10,'acceptance_recorded',length(btrim(c.acceptance_reference))>=10,
  'ready',c.outbox_handled AND length(btrim(c.backup_reference))>=10 AND length(btrim(c.acceptance_reference))>=10,
  'backup_reference',CASE WHEN can_edit THEN c.backup_reference END,
  'acceptance_reference',CASE WHEN can_edit THEN c.acceptance_reference END,
  'updated_at',c.updated_at,'updated_by_code',(SELECT code FROM pulso_v3.actors WHERE user_id=c.updated_by),
  'activated_at',c.activated_at,'activated_by_code',(SELECT code FROM pulso_v3.actors WHERE user_id=c.activated_by));
END $$;
CREATE OR REPLACE FUNCTION public.v3_company_readiness_save(p_outbox_handled boolean,p_backup_reference text,p_acceptance_reference text,p_expected bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;c pulso_v3.company_readiness;old pulso_v3.command_receipts;h text;r jsonb;b text;t text;
BEGIN
 a:=pulso_v3.require_company_operator();
 IF p_outbox_handled IS NULL OR p_backup_reference IS NULL OR p_acceptance_reference IS NULL OR
    p_expected IS NULL OR p_expected<1 OR p_request_id IS NULL OR length(p_backup_reference)>2000 OR length(p_acceptance_reference)>2000
 THEN RAISE EXCEPTION 'V3_INVALID_READINESS'; END IF;
 b:=btrim(p_backup_reference);t:=btrim(p_acceptance_reference);
 PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR UPDATE;
 h:=pulso_v3.hash(jsonb_build_object('action','company.readiness.save','outbox',p_outbox_handled,'backup',b,'acceptance',t,'expected',p_expected));
 SELECT * INTO old FROM pulso_v3.command_receipts WHERE actor_id=a.user_id AND request_id=p_request_id;
 IF FOUND THEN IF old.payload_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT';END IF;RETURN old.result||jsonb_build_object('duplicate',true);END IF;
 IF (SELECT operation_mode FROM public.settings WHERE id=1)<>'v2' THEN RAISE EXCEPTION 'V3_READINESS_ALREADY_ACTIVATED';END IF;
 SELECT * INTO c FROM pulso_v3.company_readiness WHERE id=1 FOR UPDATE;
 PERFORM pulso_v3.require_revision(c.revision,p_expected);
 UPDATE pulso_v3.company_readiness SET outbox_handled=p_outbox_handled,backup_reference=b,acceptance_reference=t,
  updated_by=a.user_id,updated_at=clock_timestamp(),revision=revision+1 WHERE id=1;
 r:=jsonb_build_object('saved',true,'revision',c.revision+1,'activated',false);
 INSERT INTO pulso_v3.command_receipts(actor_id,request_id,action,payload_hash,capability,result)
 VALUES(a.user_id,p_request_id,'company.readiness.save',h,'admin',r);
 PERFORM pulso_v3.log(a.user_id,'company.readiness.saved',NULL,p_request_id,jsonb_build_object(
   'outbox_attested',p_outbox_handled,'backup_reference',b,'acceptance_reference',t,'revision',c.revision+1,'activation_requested',false));
 PERFORM pulso_v3.signal(NULL);RETURN r;
END $$;
CREATE OR REPLACE FUNCTION public.v3_company_activate(p_expected bigint,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;c pulso_v3.company_readiness;r record;mode text;old pulso_v3.command_receipts;h text;answer jsonb;
BEGIN
 a:=pulso_v3.require_company_operator();
 IF p_expected IS NULL OR p_expected<1 OR p_request_id IS NULL THEN RAISE EXCEPTION 'V3_INVALID_READINESS';END IF;
 -- Same lock order as draft save and normal operations. No write can race the final approval.
 PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR UPDATE;
 h:=pulso_v3.hash(jsonb_build_object('action','company.activate','expected',p_expected));
 SELECT * INTO old FROM pulso_v3.command_receipts WHERE actor_id=a.user_id AND request_id=p_request_id;
 IF FOUND THEN IF old.payload_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT';END IF;RETURN old.result||jsonb_build_object('duplicate',true);END IF;
 SELECT operation_mode INTO mode FROM public.settings WHERE id=1 FOR UPDATE;
 IF mode='v3' THEN RETURN jsonb_build_object('active',true,'duplicate',true,'did_open_fieldwork',false);END IF;
 IF mode IS DISTINCT FROM 'v2' THEN RAISE EXCEPTION 'V3_CUTOVER_EVIDENCE_REQUIRED';END IF;
 SELECT * INTO c FROM pulso_v3.company_readiness WHERE id=1 FOR UPDATE;
 PERFORM pulso_v3.require_revision(c.revision,p_expected);
 IF NOT c.outbox_handled OR char_length(btrim(c.backup_reference)) NOT BETWEEN 10 AND 2000 OR
    char_length(btrim(c.acceptance_reference)) NOT BETWEEN 10 AND 2000 OR
    (SELECT count(*) FROM pulso_v3.schema_versions WHERE version BETWEEN 4 AND 13)<>10
 THEN RAISE EXCEPTION 'V3_COMPANY_CONFIRMATIONS_PENDING';END IF;
 IF EXISTS(SELECT 1 FROM public.profiles p LEFT JOIN pulso_v3.actors legacy_actor ON legacy_actor.user_id=p.id WHERE legacy_actor.user_id IS NULL OR legacy_actor.active IS DISTINCT FROM p.active OR legacy_actor.role IS DISTINCT FROM p.role)
 THEN RAISE EXCEPTION 'V3_LEGACY_ACTOR_DRIFT';END IF;
 IF EXISTS(SELECT 1 FROM public.responses) OR NOT EXISTS(SELECT 1 FROM public.settings WHERE id=1 AND state='setup') OR
    NOT EXISTS(SELECT 1 FROM pulso_v3.operations WHERE id=1 AND phase='setup') OR
    EXISTS(SELECT 1 FROM pulso_v3.responses)
 THEN RAISE EXCEPTION 'V3_LEGACY_DATA_NEEDS_REVIEW';END IF;
 FOR r IN SELECT p.oid::regprocedure sig,pg_get_functiondef(p.oid) def,p.proowner owner_id
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN(
   'bootstrap','ping','my_activity','submit_response','submit_response_v2','void_response','get_dashboard','get_dashboard_v2','get_records','get_records_v2',
   'list_accounts','list_accounts_v2','save_settings','save_catalog','set_fieldwork_state','set_assignment','set_account_active','set_viewer_access','set_operator_label','log_export') LOOP
  INSERT INTO pulso_v3.legacy_function_backups(signature,definition,original_oid,owner_name) VALUES(r.sig::text,r.def,r.sig::oid,pg_get_userbyid(r.owner_id)) ON CONFLICT(signature) DO NOTHING;
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.sig);
 END LOOP;
 REVOKE ALL ON TABLE public.districts,public.settings,public.candidates,public.stations,public.profiles,public.responses,public.audit_log,public.district_signals FROM PUBLIC,anon,authenticated,service_role;
 UPDATE public.settings SET operation_mode='v3' WHERE id=1;
 UPDATE pulso_v3.operations SET cutover_at=clock_timestamp(),backup_verified_at=clock_timestamp(),revision=revision+1 WHERE id=1;
 UPDATE pulso_v3.company_readiness SET activated_at=clock_timestamp(),activated_by=a.user_id WHERE id=1;
 PERFORM pulso_v3.log(a.user_id,'operation.v3_activated',NULL,p_request_id,jsonb_build_object(
  'responsibility','company_admin','readiness_revision',c.revision,'backup_reference',c.backup_reference,
  'acceptance_reference',c.acceptance_reference,'outbox_attested',true,'prepared_by',c.updated_by));
 answer:=jsonb_build_object('active',true,'legacy_endpoints_closed',true,'fieldwork_open',false,'responsibility','company_admin');
 INSERT INTO pulso_v3.command_receipts(actor_id,request_id,action,payload_hash,capability,result)
 VALUES(a.user_id,p_request_id,'company.activate',h,'admin',answer);
 PERFORM pulso_v3.signal(NULL);RETURN answer;
END $$;
-- Stale clients must not bypass company-owned drafts or resurrect the owner's old modal.
CREATE OR REPLACE FUNCTION public.v3_activate(p_legacy_outbox_handled boolean,p_backup_reference text,p_acceptance_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM pulso_v3.actor();
 RAISE EXCEPTION 'V3_USE_COMPANY_CONFIRMATIONS' USING ERRCODE='42501';
END $$;
REVOKE ALL ON FUNCTION pulso_v3.require_company_operator(),public.v3_company_readiness(),
 public.v3_company_readiness_save(boolean,text,text,bigint,uuid),public.v3_company_activate(bigint,uuid),
 public.v3_activate(boolean,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.v3_company_readiness(),public.v3_company_readiness_save(boolean,text,text,bigint,uuid),
 public.v3_company_activate(bigint,uuid),public.v3_activate(boolean,text,text) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(13) ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
$module013$;
 END IF;
END $owner$;
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

SELECT current_setting('pulso.module_013_before')::boolean AS module_013_before,
 EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=13) AS module_013_after,
 EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=14) AS direct_use_installed,
 (SELECT operation_mode FROM public.settings WHERE id=1) AS operation_mode,
 false AS activation_required,
 (SELECT phase FROM pulso_v3.operations WHERE id=1) AS fieldwork_phase,
 (SELECT fieldwork_date FROM pulso_v3.operations WHERE id=1) AS fieldwork_date;
COMMIT;
