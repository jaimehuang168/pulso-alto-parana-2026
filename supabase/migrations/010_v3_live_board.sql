-- Live, scoped projections independent of frozen reports. Requires V3 + addon 009.
-- Installation does not change answers, candidate names, fieldwork state or release policy.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $$BEGIN
 IF to_regprocedure('public.v3_report_alias_save(uuid,jsonb,bigint,boolean)') IS NULL THEN RAISE EXCEPTION 'V3_REPORT_MIGRATION_REQUIRED';END IF;
END$$;
CREATE TABLE IF NOT EXISTS pulso_v3.live_releases (
 district_id text PRIMARY KEY REFERENCES public.districts(id),
 questionnaire_id uuid NOT NULL REFERENCES pulso_v3.questionnaires(id),
 alias_revision bigint NOT NULL, policy_revision bigint NOT NULL,
 enabled boolean NOT NULL DEFAULT false, expires_at timestamptz NOT NULL,
 authorized_by uuid NOT NULL, authorized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 reference text NOT NULL CHECK(length(btrim(reference)) BETWEEN 10 AND 1000)
);
ALTER TABLE pulso_v3.live_releases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pulso_v3.live_releases FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX IF NOT EXISTS v3_live_current_questionnaire ON pulso_v3.responses(questionnaire_id,received_at);
CREATE OR REPLACE FUNCTION public.v3_live_authorize(p_district text,p_enabled boolean,p_expires timestamptz,p_reference text,p_confirmed boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid; q pulso_v3.questionnaires; m pulso_v3.report_aliases; p pulso_v3.report_policy;
BEGIN
 u:=pulso_v3.report_admin();
 IF p_enabled IS NULL OR p_confirmed IS DISTINCT FROM true OR length(btrim(coalesce(p_reference,''))) NOT BETWEEN 10 AND 1000 OR NOT EXISTS(SELECT 1 FROM public.districts WHERE id=p_district) THEN RAISE EXCEPTION 'V3_LIVE_AUTHORIZATION_REQUIRED';END IF;
 PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR UPDATE;
 IF NOT p_enabled THEN UPDATE pulso_v3.live_releases SET enabled=false WHERE district_id=p_district;
 ELSE
  SELECT * INTO p FROM pulso_v3.report_policy WHERE id=1 FOR SHARE;
  SELECT * INTO q FROM pulso_v3.questionnaires WHERE district_id=p_district AND state='published';
  SELECT * INTO m FROM pulso_v3.report_aliases WHERE questionnaire_id=q.id;
  IF NOT coalesce(p.enabled,false) OR p.release_not_before IS NULL OR p.release_not_before>statement_timestamp()
   OR NOT coalesce(m.confirmed,false) OR q.id IS NULL OR p_expires IS NULL OR NOT isfinite(p_expires)
   OR p_expires<=statement_timestamp() OR p_expires>statement_timestamp()+interval '24 hours'
   OR (SELECT operation_mode FROM public.settings WHERE id=1) IS DISTINCT FROM 'v3' THEN RAISE EXCEPTION 'V3_LIVE_RELEASE_BLOCKED';END IF;
  INSERT INTO pulso_v3.live_releases(district_id,questionnaire_id,alias_revision,policy_revision,enabled,expires_at,authorized_by,reference)
  VALUES(p_district,q.id,m.revision,p.revision,true,p_expires,u,btrim(p_reference))
  ON CONFLICT(district_id) DO UPDATE SET questionnaire_id=excluded.questionnaire_id,alias_revision=excluded.alias_revision,
   policy_revision=excluded.policy_revision,enabled=true,expires_at=excluded.expires_at,authorized_by=u,authorized_at=clock_timestamp(),reference=excluded.reference;
 END IF;
 PERFORM pulso_v3.signal(p_district);
 PERFORM pulso_v3.log(u,'live.authorization',NULL,NULL,jsonb_build_object('district',p_district,'enabled',p_enabled,'reference',p_reference));
 RETURN jsonb_build_object('district',p_district,'enabled',p_enabled);
END$$;
CREATE OR REPLACE FUNCTION public.v3_live_board(p_audience text DEFAULT 'auto',p_district text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; o pulso_v3.operations; d public.districts; q pulso_v3.questionnaires;
 m pulso_v3.report_aliases; p pulso_v3.report_policy; rel pulso_v3.live_releases;
 audience text; at_time timestamptz:=statement_timestamp(); board jsonb:='[]'; card jsonb; cats jsonb; others jsonb;
 n bigint; ac bigint; base bigint; pending bigint; excluded bigint; last_at timestamptz; represented bigint;
 complete_codes boolean; suppressed boolean; valid_to timestamptz:=statement_timestamp()+interval '15 seconds';
BEGIN
 a:=pulso_v3.actor();
 IF a.role NOT IN('admin','viewer') THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501';END IF;
 IF p_audience IS NULL OR p_audience NOT IN('auto','internal','codes','released') THEN RAISE EXCEPTION 'V3_LIVE_BAD_AUDIENCE';END IF;
 audience:=CASE WHEN p_audience='auto' THEN CASE WHEN a.role='admin' THEN 'codes' ELSE 'released' END ELSE p_audience END;
 IF audience IN('internal','codes') AND a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 IF p_district IS NOT NULL AND (NOT EXISTS(SELECT 1 FROM public.districts WHERE id=p_district) OR (a.role<>'admin' AND NOT pulso_v3.can(a.user_id,'view_results',p_district,NULL))) THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501';END IF;
 SELECT * INTO o FROM pulso_v3.operations WHERE id=1;
 SELECT * INTO p FROM pulso_v3.report_policy WHERE id=1;
 IF audience='released' AND NOT coalesce(o.viewer_enabled,false) THEN RAISE EXCEPTION 'V3_VIEWER_RESULTS_PENDING' USING ERRCODE='42501';END IF;
 -- One PostgreSQL statement snapshot for all cities. No voting-end requirement on private admin views.
 FOR d IN SELECT * FROM public.districts WHERE (p_district IS NULL OR id=p_district)
  AND (a.role='admin' OR pulso_v3.can(a.user_id,'view_results',id,NULL))
  ORDER BY CASE id WHEN 'cde' THEN 1 WHEN 'minga' THEN 2 WHEN 'hernandarias' THEN 3 ELSE 4 END
 LOOP
  SELECT * INTO q FROM pulso_v3.questionnaires WHERE district_id=d.id AND state='published';
  SELECT * INTO m FROM pulso_v3.report_aliases WHERE questionnaire_id=q.id;
  complete_codes:=coalesce(m.confirmed,false) AND q.id IS NOT NULL AND jsonb_array_length(m.items)=jsonb_array_length(q.items)
   AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(q.items) x WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(m.items) y WHERE y->>'candidate_id'=x->>'id'));
  card:=jsonb_build_object('id',d.id,'city',d.name,'city_code',d.code,'state','catalog_pending',
   'questionnaire_version',q.version,'alias_version',CASE WHEN complete_codes THEN m.revision END,
   'counts',NULL,'candidates','[]'::jsonb,'last_received',NULL,'coverage',NULL,'other_answers',NULL);
  IF audience='released' THEN
   SELECT * INTO rel FROM pulso_v3.live_releases WHERE district_id=d.id;
   IF NOT coalesce(p.enabled,false) OR p.release_not_before IS NULL OR p.release_not_before>at_time
    OR NOT coalesce(rel.enabled,false) OR rel.expires_at<=at_time OR rel.questionnaire_id IS DISTINCT FROM q.id
    OR rel.alias_revision IS DISTINCT FROM m.revision OR rel.policy_revision IS DISTINCT FROM p.revision OR NOT complete_codes
    OR (SELECT operation_mode FROM public.settings WHERE id=1) IS DISTINCT FROM 'v3' THEN
    board:=board||(card||jsonb_build_object('state','withheld','questionnaire_version',NULL,'alias_version',NULL));CONTINUE;
   END IF;
   valid_to:=least(valid_to,rel.expires_at);
  END IF;
  IF q.id IS NULL THEN board:=board||card;CONTINUE;END IF;
  IF audience<>'internal' AND NOT complete_codes THEN board:=board||(card||jsonb_build_object('state','codes_pending'));CONTINUE;END IF;
  SELECT count(*),count(*) FILTER(WHERE disposition='accepted'),count(*) FILTER(WHERE disposition='accepted' AND outcome='candidate'),
   count(*) FILTER(WHERE disposition='pending_review'),count(*) FILTER(WHERE disposition='excluded'),max(received_at),count(DISTINCT point_id) FILTER(WHERE disposition='accepted')
   INTO n,ac,base,pending,excluded,last_at,represented FROM pulso_v3.responses WHERE questionnaire_id=q.id AND received_at<=at_time;
  SELECT coalesce(jsonb_agg(jsonb_build_object('code',CASE WHEN complete_codes THEN (SELECT x->>'code' FROM jsonb_array_elements(m.items)x WHERE x->>'candidate_id'=v->>'id') END,
   'count',(SELECT count(*) FROM pulso_v3.responses r WHERE r.questionnaire_id=q.id AND r.candidate_id=(v->>'id')::uuid AND r.disposition='accepted' AND r.received_at<=at_time))
   ||CASE WHEN audience='internal' THEN jsonb_build_object('real_name',v->>'name','list',v->>'list') ELSE '{}'::jsonb END ORDER BY ord),'[]')
   INTO cats FROM jsonb_array_elements(q.items) WITH ORDINALITY z(v,ord);
  SELECT jsonb_object_agg(t.kind,(SELECT count(*) FROM pulso_v3.responses r WHERE r.questionnaire_id=q.id AND r.outcome=t.kind AND r.disposition='accepted' AND r.received_at<=at_time))
   INTO others FROM (VALUES('blank'),('invalid'),('undisclosed'),('refused')) t(kind);
  suppressed:=audience='released' AND (base<o.viewer_min_base OR EXISTS(SELECT 1 FROM jsonb_array_elements(cats) x WHERE (x->>'count')::bigint BETWEEN 1 AND 4));
  IF suppressed THEN board:=board||(card||jsonb_build_object('state','suppressed'));CONTINUE;END IF;
  card:=card||jsonb_build_object('state',CASE WHEN n=0 THEN 'no_data' ELSE 'live' END,'candidates',cats,'last_received',last_at,
   'counts',CASE WHEN audience='released' THEN jsonb_build_object('candidate_base',base) ELSE jsonb_build_object('received',n,'accepted',ac,'candidate_base',base,'pending_review',pending,'excluded',excluded) END,
   'other_answers',CASE WHEN audience='released' THEN NULL ELSE others END,
   'coverage',jsonb_build_object('represented_points',represented,'configured_points',(SELECT count(*) FROM pulso_v3.points pt JOIN pulso_v3.stations st ON st.id=pt.station_id WHERE st.district_id=d.id)));
  board:=board||card;
 END LOOP;
 RETURN jsonb_build_object('schema','pulso-live-1','audience',audience,'private',audience<>'released','can_internal',a.role='admin',
  'server_time',at_time,'valid_until',valid_to,'poll_ms',5000,'timezone','America/Asuncion','election_date',o.fieldwork_date,'cities',board,
  'base_definition','Respuestas aceptadas con candidatura, de la versión publicada. No incluye blancos, nulos, no revela ni rechazos.',
  'limitations','Muestra parcial no ponderada. No es escrutinio ni resultado oficial. No confundir ausencia de cobertura con cero votos.');
END$$;
REVOKE ALL ON FUNCTION public.v3_live_board(text,text),public.v3_live_authorize(text,boolean,timestamptz,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.v3_live_board(text,text),public.v3_live_authorize(text,boolean,timestamptz,text,boolean) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(10) ON CONFLICT(version) DO NOTHING;
COMMIT;
