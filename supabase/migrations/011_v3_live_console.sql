-- Pulso live console: privileged status + bounded viewer expiry. No collection or release is enabled.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $$BEGIN
 IF to_regprocedure('public.v3_live_board(text,text)') IS NULL THEN RAISE EXCEPTION 'V3_LIVE_MIGRATION_REQUIRED';END IF;
END$$;
CREATE OR REPLACE FUNCTION public.v3_live_admin_state() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;BEGIN
 u:=pulso_v3.report_admin();
 RETURN jsonb_build_object('schema','pulso-live-admin-1','server_time',statement_timestamp(),
 'operation_mode',(SELECT operation_mode FROM public.settings WHERE id=1),
 'operation',(SELECT jsonb_build_object('phase',phase,'viewer_enabled',viewer_enabled,'viewer_min_base',viewer_min_base,'revision',revision) FROM pulso_v3.operations WHERE id=1),
 'policy',(SELECT to_jsonb(p) FROM pulso_v3.report_policy p WHERE id=1),
 'cities',(SELECT jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'code',d.code,
   'config',(SELECT public.v3_report_config(q.id) FROM pulso_v3.questionnaires q WHERE q.district_id=d.id AND q.state='published'),
   'release',(SELECT to_jsonb(l) FROM pulso_v3.live_releases l WHERE l.district_id=d.id)) ORDER BY d.sort_order) FROM public.districts d));
END$$;
REVOKE ALL ON FUNCTION public.v3_live_admin_state() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.v3_live_admin_state() TO authenticated;
-- Bound a cached display by each shown city's longest currently valid viewer grant.
DO $$BEGIN
 IF to_regprocedure('pulso_v3.live_board_before_console(text,text)') IS NULL THEN
  ALTER FUNCTION public.v3_live_board(text,text) SET SCHEMA pulso_v3;
  ALTER FUNCTION pulso_v3.v3_live_board(text,text) RENAME TO live_board_before_console;
 END IF;
END$$;
REVOKE ALL ON FUNCTION pulso_v3.live_board_before_console(text,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.v3_live_board(p_audience text DEFAULT 'auto',p_district text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; b jsonb; expires timestamptz;BEGIN
 a:=pulso_v3.actor(); b:=pulso_v3.live_board_before_console(p_audience,p_district);
 IF a.role='viewer' THEN
  SELECT min(t.latest) INTO expires FROM (
   SELECT max(g.valid_until) latest FROM pulso_v3.role_grants g
   WHERE g.user_id=a.user_id AND g.revoked_at IS NULL AND g.valid_from<=statement_timestamp()
    AND g.valid_until>statement_timestamp() AND g.point_id IS NULL AND 'view_results'=ANY(g.capabilities)
    AND EXISTS(SELECT 1 FROM jsonb_array_elements(b->'cities') c WHERE c->>'id'=g.district_id)
   GROUP BY g.district_id
  ) t;
  IF expires IS NOT NULL THEN b:=jsonb_set(b,'{valid_until}',to_jsonb(least(expires,(b->>'valid_until')::timestamptz)));END IF;
 END IF;
 RETURN b;
END$$;
REVOKE ALL ON FUNCTION public.v3_live_board(text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.v3_live_board(text,text) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(11) ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
