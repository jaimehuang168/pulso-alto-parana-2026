-- Installs preflight and explicit cutover control; does NOT switch operation_mode.
BEGIN;
CREATE FUNCTION public.v3_preflight() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;BEGIN
 a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('operation_mode',(SELECT operation_mode FROM public.settings WHERE id=1),
  'legacy_responses',(SELECT count(*) FROM public.responses),'v3_responses',(SELECT count(*) FROM pulso_v3.responses),
  'legacy_actor_drift',(SELECT count(*) FROM public.profiles p LEFT JOIN pulso_v3.actors legacy_actor ON legacy_actor.user_id=p.id WHERE legacy_actor.user_id IS NULL OR legacy_actor.active IS DISTINCT FROM p.active OR legacy_actor.role IS DISTINCT FROM p.role),
  'migrations',(SELECT jsonb_agg(version ORDER BY version) FROM pulso_v3.schema_versions),
  'outbox_status','MUST_BE_ATTESTED_BY_OWNERS','production_auth_and_devices','EXTERNAL_ACCEPTANCE_REQUIRED');
END $$;
CREATE FUNCTION public.v3_activate(p_legacy_outbox_handled boolean,p_backup_reference text,p_acceptance_reference text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;r record;mode text;
BEGIN
 a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 SELECT operation_mode INTO mode FROM public.settings WHERE id=1 FOR UPDATE;
 IF mode='v3' THEN RETURN jsonb_build_object('active',true,'duplicate',true);END IF;
 IF p_legacy_outbox_handled IS DISTINCT FROM true OR char_length(btrim(p_backup_reference))<10 OR char_length(btrim(p_acceptance_reference))<10
  OR (SELECT count(*) FROM pulso_v3.schema_versions WHERE version IN(4,5,6,7,8))<>5 THEN RAISE EXCEPTION 'V3_CUTOVER_EVIDENCE_REQUIRED';END IF;
 IF EXISTS(SELECT 1 FROM public.profiles p LEFT JOIN pulso_v3.actors legacy_actor ON legacy_actor.user_id=p.id WHERE legacy_actor.user_id IS NULL OR legacy_actor.active IS DISTINCT FROM p.active OR legacy_actor.role IS DISTINCT FROM p.role) THEN RAISE EXCEPTION 'V3_LEGACY_ACTOR_DRIFT';END IF;
 IF EXISTS(SELECT 1 FROM public.responses) OR EXISTS(SELECT 1 FROM public.settings WHERE state<>'setup') THEN RAISE EXCEPTION 'V3_LEGACY_DATA_NEEDS_REVIEW';END IF;
 -- Do not rewrite legacy implementations. Close every prior application entry point and direct table read.
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
 PERFORM pulso_v3.log(a.user_id,'operation.v3_activated',NULL,NULL,jsonb_build_object('backup_reference',p_backup_reference,'acceptance_reference',p_acceptance_reference,'outbox_attested',true));
 RETURN jsonb_build_object('active',true,'legacy_endpoints_closed',true,'fieldwork_open',false);
END $$;
REVOKE ALL ON FUNCTION public.v3_preflight(),public.v3_activate(boolean,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_preflight(),public.v3_activate(boolean,text,text) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(7);
COMMIT;
