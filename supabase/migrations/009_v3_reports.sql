-- Pulso V3.1: real-name collection, private reconciliation, alias-only external cuts.
-- Additive, repeatable. Does not change questionnaires, survey answers or collection state.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $$BEGIN
 IF to_regprocedure('public.v3_submit_response(jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'V3_INSTALL_REQUIRED';END IF;
END$$;
CREATE TABLE IF NOT EXISTS pulso_v3.report_aliases (
 questionnaire_id uuid PRIMARY KEY REFERENCES pulso_v3.questionnaires(id),
 items jsonb NOT NULL, revision bigint NOT NULL DEFAULT 1,
 confirmed boolean NOT NULL DEFAULT false, confirmed_by uuid, confirmed_at timestamptz,
 CHECK(jsonb_typeof(items)='array'), CHECK(NOT confirmed OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS pulso_v3.report_policy (
 id integer PRIMARY KEY CHECK(id=1), enabled boolean NOT NULL DEFAULT false,
 release_not_before timestamptz, authorization_reference text NOT NULL DEFAULT '',
 revision bigint NOT NULL DEFAULT 1, updated_by uuid, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(NOT enabled OR (release_not_before IS NOT NULL AND length(btrim(authorization_reference))>=10))
);
INSERT INTO pulso_v3.report_policy(id) VALUES(1) ON CONFLICT(id) DO NOTHING;
CREATE TABLE IF NOT EXISTS pulso_v3.report_cuts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
 request_id uuid NOT NULL, request_hash text NOT NULL,
 district_id text NOT NULL REFERENCES public.districts(id), questionnaire_id uuid NOT NULL REFERENCES pulso_v3.questionnaires(id),
 cut_number bigint GENERATED ALWAYS AS IDENTITY, cutoff_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 alias_revision bigint NOT NULL, source_revision bigint NOT NULL,
 internal_payload jsonb NOT NULL, external_payload jsonb NOT NULL,
 status text NOT NULL DEFAULT 'draft' CHECK(status IN('draft','released','revoked')),
 released_at timestamptz, released_by uuid, release_reference text, revoked_at timestamptz, revoked_reason text,
 UNIQUE(owner_id,request_id)
);
ALTER TABLE pulso_v3.report_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE pulso_v3.report_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE pulso_v3.report_cuts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pulso_v3.report_aliases,pulso_v3.report_policy,pulso_v3.report_cuts FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION pulso_v3.report_admin() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;BEGIN a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;RETURN a.user_id;END$$;
CREATE OR REPLACE FUNCTION pulso_v3.report_normalize(t text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='' AS $$ SELECT regexp_replace(translate(lower(btrim(coalesce(t,''))),'áéíóúüñ','aeiouun'),'[^a-z0-9]+',' ','g') $$;
CREATE OR REPLACE FUNCTION public.v3_report_config(p_questionnaire uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE q pulso_v3.questionnaires;m pulso_v3.report_aliases;d public.districts;BEGIN
 PERFORM pulso_v3.report_admin();SELECT * INTO q FROM pulso_v3.questionnaires WHERE id=p_questionnaire;
 IF q.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND';END IF;
 SELECT * INTO d FROM public.districts WHERE id=q.district_id;
 SELECT * INTO m FROM pulso_v3.report_aliases WHERE questionnaire_id=q.id;
 RETURN jsonb_build_object('questionnaire_id',q.id,'city',d.name,'district_id',d.id,'version',q.version,'questionnaire_state',q.state,
 'alias_revision',coalesce(m.revision,0),'confirmed',coalesce(m.confirmed,false),'policy',(SELECT to_jsonb(p) FROM pulso_v3.report_policy p WHERE id=1),
 'items',(SELECT jsonb_agg(jsonb_build_object('candidate_id',v->>'id','real_name',v->>'name','list',v->>'list','code',coalesce((SELECT x->>'code' FROM jsonb_array_elements(coalesce(m.items,'[]')) x WHERE x->>'candidate_id'=v->>'id'),d.code||'-'||chr(64+n::integer))) ORDER BY n) FROM jsonb_array_elements(q.items) WITH ORDINALITY z(v,n)));
END$$;
CREATE OR REPLACE FUNCTION public.v3_report_alias_save(p_questionnaire uuid,p_items jsonb,p_expected bigint,p_confirmed boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;q pulso_v3.questionnaires;m pulso_v3.report_aliases;v jsonb;clean jsonb:='[]';codes text[]:='{}';ids text[]:='{}';code text;norm text;token text;BEGIN
 u:=pulso_v3.report_admin();PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR UPDATE;
 SELECT * INTO q FROM pulso_v3.questionnaires WHERE id=p_questionnaire;IF q.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND';END IF;
 SELECT * INTO m FROM pulso_v3.report_aliases WHERE questionnaire_id=q.id FOR UPDATE;
 PERFORM pulso_v3.require_revision(coalesce(m.revision,0),p_expected);
 IF p_confirmed IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)<>jsonb_array_length(q.items) THEN RAISE EXCEPTION 'V3_ALIAS_COMPLETE_REQUIRED';END IF;
 FOR v IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF jsonb_typeof(v) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(v) k WHERE k NOT IN('candidate_id','code')) OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(q.items) x WHERE x->>'id'=v->>'candidate_id') OR (v->>'candidate_id')=ANY(ids) THEN RAISE EXCEPTION 'V3_ALIAS_COMPLETE_REQUIRED';END IF;
  code:=regexp_replace(btrim(coalesce(v->>'code','')),'\s+',' ','g');norm:=pulso_v3.report_normalize(code);
  IF length(code) NOT BETWEEN 2 AND 40 OR code !~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ][A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ ._-]*$' OR norm=ANY(codes) OR norm~'(^| )lista( |$)' THEN RAISE EXCEPTION 'V3_ALIAS_INVALID_OR_DUPLICATE';END IF;
  FOR token IN SELECT DISTINCT t FROM jsonb_array_elements(q.items) x CROSS JOIN LATERAL regexp_split_to_table(pulso_v3.report_normalize(x->>'name'),' ') t WHERE length(t)>=3 LOOP
   IF strpos(' '||norm||' ',' '||token||' ')>0 THEN RAISE EXCEPTION 'V3_ALIAS_CONTAINS_REAL_NAME';END IF;
  END LOOP;
  ids:=array_append(ids,v->>'candidate_id');codes:=array_append(codes,norm);clean:=clean||jsonb_build_object('candidate_id',v->>'candidate_id','code',code);
 END LOOP;
 INSERT INTO pulso_v3.report_aliases(questionnaire_id,items,revision,confirmed,confirmed_by,confirmed_at)
 VALUES(q.id,clean,1,p_confirmed,CASE WHEN p_confirmed THEN u END,CASE WHEN p_confirmed THEN clock_timestamp() END)
 ON CONFLICT(questionnaire_id) DO UPDATE SET items=excluded.items,revision=report_aliases.revision+1,confirmed=excluded.confirmed,confirmed_by=excluded.confirmed_by,confirmed_at=excluded.confirmed_at;
 UPDATE pulso_v3.report_cuts SET status='revoked',revoked_at=clock_timestamp(),revoked_reason='ALIAS_CHANGED' WHERE questionnaire_id=q.id AND status='released';
 PERFORM pulso_v3.log(u,'report.alias_saved',q.id,NULL,jsonb_build_object('confirmed',p_confirmed,'revision',coalesce(m.revision,0)+1));
 RETURN public.v3_report_config(q.id);
END$$;
CREATE OR REPLACE FUNCTION public.v3_report_policy_save(p_enabled boolean,p_not_before timestamptz,p_reference text,p_expected bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;p pulso_v3.report_policy;BEGIN
 u:=pulso_v3.report_admin();SELECT * INTO p FROM pulso_v3.report_policy WHERE id=1 FOR UPDATE;PERFORM pulso_v3.require_revision(p.revision,p_expected);
 IF p_enabled IS NULL OR (p_enabled AND (p_not_before IS NULL OR NOT isfinite(p_not_before) OR length(btrim(coalesce(p_reference,''))) NOT BETWEEN 10 AND 1000)) THEN RAISE EXCEPTION 'V3_RELEASE_AUTHORIZATION_REQUIRED';END IF;
 UPDATE pulso_v3.report_policy SET enabled=p_enabled,release_not_before=p_not_before,authorization_reference=btrim(coalesce(p_reference,'')),revision=revision+1,updated_by=u,updated_at=clock_timestamp() WHERE id=1;
 PERFORM pulso_v3.log(u,'report.release_policy',NULL,NULL,jsonb_build_object('enabled',p_enabled,'not_before',p_not_before));
 RETURN (SELECT to_jsonb(saved_policy) FROM pulso_v3.report_policy saved_policy WHERE id=1);
END$$;
CREATE OR REPLACE FUNCTION public.v3_report_create(p_questionnaire uuid,p_cutoff timestamptz,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;q pulso_v3.questionnaires;m pulso_v3.report_aliases;o pulso_v3.operations;d public.districts;r pulso_v3.report_cuts;
 at_time timestamptz:=statement_timestamp();co timestamptz;h text;raw jsonb;cats jsonb;extcats jsonb;other jsonb;stats jsonb;pub jsonb;inside jsonb;rid uuid:=gen_random_uuid();cut bigint;
 n integer;naccepted integer;nbase integer;npending integer;nexcluded integer;suppressed boolean;BEGIN
 u:=pulso_v3.report_admin();SELECT * INTO o FROM pulso_v3.operations WHERE id=1 FOR UPDATE;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'V3_INVALID_COMMAND';END IF;
 h:=pulso_v3.hash(jsonb_build_object('q',p_questionnaire,'cutoff',p_cutoff));
 SELECT * INTO r FROM pulso_v3.report_cuts WHERE owner_id=u AND request_id=p_request_id;
 IF FOUND THEN IF r.request_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT';END IF;RETURN jsonb_build_object('id',r.id,'duplicate',true);END IF;
 SELECT * INTO q FROM pulso_v3.questionnaires WHERE id=p_questionnaire;
 IF q.id IS NULL OR q.state='draft' THEN RAISE EXCEPTION 'V3_QUESTIONNAIRE_NOT_PUBLISHED';END IF;
 SELECT * INTO m FROM pulso_v3.report_aliases WHERE questionnaire_id=q.id;
 IF m.questionnaire_id IS NULL OR NOT m.confirmed OR jsonb_array_length(m.items)<>jsonb_array_length(q.items) OR EXISTS(SELECT 1 FROM jsonb_array_elements(q.items)x WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(m.items)c WHERE c->>'candidate_id'=x->>'id')) THEN RAISE EXCEPTION 'V3_ALIAS_CONFIRM_REQUIRED';END IF;
 SELECT * INTO d FROM public.districts WHERE id=q.district_id;
 co:=coalesce(p_cutoff,at_time);IF NOT isfinite(co) OR co>at_time OR co<(o.fieldwork_date::timestamp AT TIME ZONE 'America/Asuncion') THEN RAISE EXCEPTION 'V3_REPORT_CUTOFF_INVALID';END IF;
 -- Freeze once: every aggregate and both outputs derive from this exact source array.
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.received_at,x.id),'[]') INTO raw FROM (
  SELECT a.id,a.receipt_id,a.candidate_id,a.outcome,a.consent,a.already_voted,a.questionnaire_id,q.version questionnaire_version,a.assignment_id,a.person_id,w.code person_code,w.display_name person_name,
   a.point_id,p.code point_code,p.label point_label,s.code station_code,s.name station_name,s.address station_address,a.started_at,a.captured_at,a.received_at,a.source,a.time_precision,a.paper_batch,a.paper_number,a.disposition,a.reason_code,a.revision,
   (SELECT c->>'name' FROM jsonb_array_elements(q.items)c WHERE c->>'id'=a.candidate_id::text) real_name,
   (SELECT c->>'list' FROM jsonb_array_elements(q.items)c WHERE c->>'id'=a.candidate_id::text) list,
   (SELECT c->>'code' FROM jsonb_array_elements(m.items)c WHERE c->>'candidate_id'=a.candidate_id::text) external_code
  FROM pulso_v3.responses a JOIN pulso_v3.people w ON w.id=a.person_id JOIN pulso_v3.points p ON p.id=a.point_id JOIN pulso_v3.stations s ON s.id=p.station_id
  WHERE a.questionnaire_id=q.id AND a.received_at<=co ORDER BY a.received_at,a.id LIMIT 100001
 )x;
 n:=jsonb_array_length(raw);IF n>100000 THEN RAISE EXCEPTION 'V3_EXPORT_FILTER_REQUIRED';END IF;
 SELECT count(*) FILTER(WHERE x->>'disposition'='accepted'),count(*) FILTER(WHERE x->>'disposition'='accepted' AND x->>'outcome'='candidate'),count(*) FILTER(WHERE x->>'disposition'='pending_review'),count(*) FILTER(WHERE x->>'disposition'='excluded') INTO naccepted,nbase,npending,nexcluded FROM jsonb_array_elements(raw)x;
 SELECT jsonb_agg(jsonb_build_object('candidate_id',v->>'id','real_name',v->>'name','list',v->>'list','code',(SELECT a->>'code' FROM jsonb_array_elements(m.items)a WHERE a->>'candidate_id'=v->>'id'),
 'count',(SELECT count(*) FROM jsonb_array_elements(raw)x WHERE x->>'candidate_id'=v->>'id' AND x->>'disposition'='accepted')) ORDER BY ord) INTO cats FROM jsonb_array_elements(q.items) WITH ORDINALITY z(v,ord);
 SELECT jsonb_object_agg(t.code,(SELECT count(*) FROM jsonb_array_elements(raw)x WHERE x->>'outcome'=t.code AND x->>'disposition'='accepted')) INTO other FROM (VALUES('blank'),('invalid'),('undisclosed'),('refused'))t(code);
 suppressed:=nbase<o.viewer_min_base OR EXISTS(SELECT 1 FROM jsonb_array_elements(cats)x WHERE (x->>'count')::integer BETWEEN 1 AND 4);
 -- Public output is built by allowlist, never by hiding private fields in CSS.
 SELECT jsonb_agg(jsonb_build_object('code',x->>'code','count',(x->>'count')::integer) ORDER BY ord) INTO extcats FROM jsonb_array_elements(cats) WITH ORDINALITY z(x,ord);
 cut:=nextval(pg_get_serial_sequence('pulso_v3.report_cuts','cut_number'));
 stats:=jsonb_build_object('received',n,'accepted',naccepted,'pending_review',npending,'excluded',nexcluded,'candidate_base',nbase,'other_answers',other);
 pub:=jsonb_build_object('schema','pulso-external-1','report_id',rid,'cut_number',cut,'city',d.name,'city_code',d.code,'cutoff_at',co,'snapshot_at',at_time,'timezone','America/Asuncion','election_date',o.fieldwork_date,
 'contest','Intendencia municipal','questionnaire_version',q.version,'alias_version',m.revision,'suppressed',suppressed,
 'candidate_base',CASE WHEN suppressed THEN NULL ELSE nbase END,'candidates',CASE WHEN suppressed THEN '[]'::jsonb ELSE extcats END,
 'configured_points',(SELECT count(*) FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE s.district_id=d.id),
 'represented_points',(SELECT count(DISTINCT x->>'point_id') FROM jsonb_array_elements(raw)x WHERE x->>'disposition'='accepted'),
 'base_definition','Respuestas aceptadas que declaran una candidatura; blancos, nulos, no revela y rechazos fuera de la base.',
 'limitations','Muestra no ponderada de puntos configurados. No es escrutinio ni resultado oficial. El uso de códigos no equivale a anonimato ni permiso de difusión.');
 inside:=jsonb_build_object('schema','pulso-internal-1','report_id',rid,'cut_number',cut,'city',d.name,'city_code',d.code,'district_id',d.id,'questionnaire_id',q.id,'questionnaire_version',q.version,'alias_version',m.revision,'cutoff_at',co,'snapshot_at',at_time,'timezone','America/Asuncion','election_date',o.fieldwork_date,
 'methodology',q.methodology,'sample_interval',q.sample_interval,'candidates',cats,'stats',stats,'records',raw,'source_revision',o.revision,
 'cutoff_definition','Recibidas en servidor hasta el corte; estado de revisión congelado al generar. Las horas del teléfono se mantienen para auditoría.');
 INSERT INTO pulso_v3.report_cuts(id,owner_id,request_id,request_hash,district_id,questionnaire_id,cut_number,cutoff_at,created_at,alias_revision,source_revision,internal_payload,external_payload)
 OVERRIDING SYSTEM VALUE VALUES(rid,u,p_request_id,h,d.id,q.id,cut,co,at_time,m.revision,o.revision,inside,pub);
 PERFORM pulso_v3.log(u,'report.cut_created',rid,p_request_id,jsonb_build_object('district_id',d.id,'questionnaire_id',q.id,'alias_revision',m.revision,'records',n,'cutoff',co));
 RETURN jsonb_build_object('id',rid,'duplicate',false);
END$$;
CREATE OR REPLACE FUNCTION public.v3_report_read(p_id uuid,p_audience text,p_offset integer DEFAULT 0,p_limit integer DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;r pulso_v3.report_cuts;p pulso_v3.report_policy;total integer;BEGIN
 a:=pulso_v3.actor();SELECT * INTO r FROM pulso_v3.report_cuts WHERE id=p_id;SELECT * INTO p FROM pulso_v3.report_policy WHERE id=1;
 IF r.id IS NULL OR p_audience IS NULL OR p_audience NOT IN('internal','external') OR p_offset IS NULL OR p_limit IS NULL OR p_offset<0 OR p_limit NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'V3_INVALID_EXPORT';END IF;
 IF p_audience='internal' THEN
  IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
  total:=jsonb_array_length(r.internal_payload->'records');
  RETURN (r.internal_payload-'records')||jsonb_build_object('audience','internal','status',r.status,'total_records',total,'next_offset',CASE WHEN p_offset+p_limit<total THEN p_offset+p_limit END,'records',(SELECT coalesce(jsonb_agg(v ORDER BY ord),'[]') FROM jsonb_array_elements(r.internal_payload->'records') WITH ORDINALITY z(v,ord) WHERE ord>p_offset AND ord<=p_offset+p_limit));
 END IF;
 IF a.role<>'admin' AND NOT (a.role='viewer' AND r.status='released' AND p.enabled AND p.release_not_before<=statement_timestamp() AND (SELECT viewer_enabled FROM pulso_v3.operations WHERE id=1) AND pulso_v3.can(a.user_id,'view_results',r.district_id,NULL)) THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501';END IF;
 RETURN r.external_payload||jsonb_build_object('audience','external','status',CASE WHEN r.status='released' AND (NOT p.enabled OR p.release_not_before>statement_timestamp()) THEN 'withheld' ELSE r.status END,'released_at',r.released_at);
END$$;
CREATE OR REPLACE FUNCTION public.v3_report_list() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN PERFORM pulso_v3.report_admin();RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]') FROM (SELECT id,district_id,cut_number,cutoff_at,created_at,status,questionnaire_id,alias_revision,external_payload->>'city' city FROM pulso_v3.report_cuts ORDER BY created_at DESC LIMIT 100)x);END$$;
CREATE OR REPLACE FUNCTION public.v3_report_release(p_id uuid,p_confirmed boolean,p_reference text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r pulso_v3.report_cuts;p pulso_v3.report_policy;m pulso_v3.report_aliases;BEGIN
 u:=pulso_v3.report_admin();PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR UPDATE;SELECT * INTO p FROM pulso_v3.report_policy WHERE id=1 FOR SHARE;SELECT * INTO r FROM pulso_v3.report_cuts WHERE id=p_id FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND';END IF;
 IF p_confirmed IS DISTINCT FROM true OR length(btrim(coalesce(p_reference,''))) NOT BETWEEN 10 AND 1000 OR NOT p.enabled OR p.release_not_before IS NULL OR p.release_not_before>statement_timestamp() OR (SELECT operation_mode FROM public.settings WHERE id=1)<>'v3' THEN RAISE EXCEPTION 'V3_REPORT_RELEASE_BLOCKED';END IF;
 SELECT * INTO m FROM pulso_v3.report_aliases WHERE questionnaire_id=r.questionnaire_id;
 IF NOT m.confirmed OR m.revision<>r.alias_revision OR NOT EXISTS(SELECT 1 FROM pulso_v3.questionnaires WHERE id=r.questionnaire_id AND state='published') OR r.status='revoked' THEN RAISE EXCEPTION 'V3_REPORT_STALE';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(r.internal_payload->'records') x LEFT JOIN pulso_v3.responses s ON s.id=(x->>'id')::uuid WHERE s.id IS NULL OR s.revision IS DISTINCT FROM (x->>'revision')::bigint) THEN RAISE EXCEPTION 'V3_REPORT_STALE';END IF;
 UPDATE pulso_v3.report_cuts SET status='released',released_at=coalesce(released_at,clock_timestamp()),released_by=u,release_reference=btrim(p_reference) WHERE id=r.id AND status IN('draft','released');
 PERFORM pulso_v3.log(u,'report.released',r.id,NULL,jsonb_build_object('reference',p_reference,'cutoff',r.cutoff_at));RETURN public.v3_report_read(r.id,'external');
END$$;
CREATE OR REPLACE FUNCTION public.v3_report_revoke(p_id uuid,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;BEGIN u:=pulso_v3.report_admin();IF length(btrim(coalesce(p_reason,''))) NOT BETWEEN 10 AND 1000 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED';END IF;
 UPDATE pulso_v3.report_cuts SET status='revoked',revoked_at=clock_timestamp(),revoked_reason=p_reason WHERE id=p_id AND status IN('draft','released');
 IF NOT FOUND THEN RAISE EXCEPTION 'V3_NOT_FOUND';END IF;PERFORM pulso_v3.log(u,'report.revoked',p_id,NULL,jsonb_build_object('reason',p_reason));RETURN jsonb_build_object('revoked',true);END$$;
CREATE OR REPLACE FUNCTION pulso_v3.report_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$BEGIN
 IF TG_OP='DELETE' OR (to_jsonb(NEW)-ARRAY['status','released_at','released_by','release_reference','revoked_at','revoked_reason']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','released_at','released_by','release_reference','revoked_at','revoked_reason']) THEN RAISE EXCEPTION 'V3_IMMUTABLE_REPORT';END IF;RETURN NEW;END$$;
DROP TRIGGER IF EXISTS v3_report_immutable ON pulso_v3.report_cuts;
CREATE TRIGGER v3_report_immutable BEFORE UPDATE OR DELETE ON pulso_v3.report_cuts FOR EACH ROW EXECUTE FUNCTION pulso_v3.report_immutable();
CREATE OR REPLACE FUNCTION pulso_v3.report_invalidate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN
 IF NEW.disposition IS DISTINCT FROM OLD.disposition THEN
  UPDATE pulso_v3.report_cuts SET status='revoked',revoked_at=clock_timestamp(),revoked_reason='SOURCE_REVIEW_CHANGED' WHERE status='released' AND questionnaire_id=NEW.questionnaire_id AND cutoff_at>=NEW.received_at;
 END IF;RETURN NEW;END$$;
DROP TRIGGER IF EXISTS v3_report_review_changed ON pulso_v3.responses;
CREATE TRIGGER v3_report_review_changed AFTER UPDATE OF disposition ON pulso_v3.responses FOR EACH ROW EXECUTE FUNCTION pulso_v3.report_invalidate();
CREATE OR REPLACE FUNCTION pulso_v3.report_questionnaire_changed() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN
 IF OLD.state='published' AND NEW.state<>'published' THEN
  UPDATE pulso_v3.report_cuts SET status='revoked',revoked_at=clock_timestamp(),revoked_reason='QUESTIONNAIRE_REPLACED' WHERE questionnaire_id=NEW.id AND status='released';
 END IF;RETURN NEW;END$$;
DROP TRIGGER IF EXISTS v3_report_questionnaire_changed ON pulso_v3.questionnaires;
CREATE TRIGGER v3_report_questionnaire_changed AFTER UPDATE OF state ON pulso_v3.questionnaires FOR EACH ROW EXECUTE FUNCTION pulso_v3.report_questionnaire_changed();
-- Close old true-name viewer publication. Keep existing admin/worker behavior.
DO $$BEGIN
 IF to_regprocedure('pulso_v3.command_before_reports(text,jsonb,uuid,bigint,integer)') IS NULL THEN
  ALTER FUNCTION public.v3_command(text,jsonb,uuid,bigint,integer) SET SCHEMA pulso_v3;
  ALTER FUNCTION pulso_v3.v3_command(text,jsonb,uuid,bigint,integer) RENAME TO command_before_reports;
 END IF;
 IF to_regprocedure('pulso_v3.dashboard_before_reports(text)') IS NULL THEN
  ALTER FUNCTION public.v3_dashboard(text) SET SCHEMA pulso_v3;
  ALTER FUNCTION pulso_v3.v3_dashboard(text) RENAME TO dashboard_before_reports;
 END IF;
END$$;
REVOKE ALL ON FUNCTION pulso_v3.command_before_reports(text,jsonb,uuid,bigint,integer),pulso_v3.dashboard_before_reports(text) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.v3_command(p_action text,p_data jsonb,p_request_id uuid,p_expected bigint DEFAULT 0,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN
 PERFORM pulso_v3.actor();IF p_action='viewer.publish' THEN RAISE EXCEPTION 'V3_USE_ALIAS_REPORTS';END IF;
 RETURN pulso_v3.command_before_reports(p_action,p_data,p_request_id,p_expected,p_client);
END$$;
CREATE OR REPLACE FUNCTION public.v3_dashboard(p_district text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;p pulso_v3.report_policy;BEGIN
 a:=pulso_v3.actor();IF a.role<>'viewer' THEN RETURN pulso_v3.dashboard_before_reports(p_district);END IF;
 SELECT * INTO p FROM pulso_v3.report_policy WHERE id=1;
 IF NOT (SELECT viewer_enabled FROM pulso_v3.operations WHERE id=1) THEN RAISE EXCEPTION 'V3_VIEWER_RESULTS_PENDING' USING ERRCODE='42501';END IF;
 IF p_district IS NOT NULL AND NOT pulso_v3.can(a.user_id,'view_results',p_district,NULL) THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('server_time',statement_timestamp(),'read_only',true,'alias_reports',true,'cities',
 (SELECT coalesce(jsonb_agg(payload ORDER BY district_id),'[]') FROM (
  SELECT DISTINCT ON(r.district_id) r.district_id, public.v3_report_read(r.id,'external') AS payload
  FROM pulso_v3.report_cuts r JOIN pulso_v3.questionnaires q ON q.id=r.questionnaire_id
  WHERE r.status='released' AND q.state='published' AND p.enabled AND p.release_not_before<=statement_timestamp() AND pulso_v3.can(a.user_id,'view_results',r.district_id,NULL) AND (p_district IS NULL OR r.district_id=p_district)
  ORDER BY r.district_id,r.cutoff_at DESC,r.created_at DESC)x));
END$$;
-- Only legacy name-bearing viewer caches are revoked; no survey answers are deleted.
DELETE FROM pulso_v3.viewer_snapshots WHERE payload IS NOT NULL;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pulso_v3 FROM PUBLIC,anon,authenticated;
DO $$DECLARE f regprocedure;BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND (p.proname LIKE 'v3_report_%' OR p.proname IN('v3_command','v3_dashboard')) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,service_role',f);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f);
 END LOOP;
END$$;
INSERT INTO pulso_v3.schema_versions(version) VALUES(9) ON CONFLICT(version) DO NOTHING;
COMMIT;
