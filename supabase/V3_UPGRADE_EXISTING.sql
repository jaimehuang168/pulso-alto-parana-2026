-- PULSO V3 增量升級：只用於已完整安裝 V2、尚未開收的專用專案。
-- 不開收、不停用RLS、不刪帳號/問卷/稽核；只新增V3結構。
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $$BEGIN
 IF to_regprocedure('public.submit_response_v2(jsonb)') IS NULL OR to_regclass('public.profiles') IS NULL THEN RAISE EXCEPTION '完整V2尚未安裝。未更動資料。';END IF;
 IF EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='pulso_v3') THEN RAISE EXCEPTION 'V3結構已存在，請核對migration狀態，不重跑或刪表。';END IF;
 IF EXISTS(SELECT 1 FROM public.responses) OR EXISTS(SELECT 1 FROM public.settings WHERE state<>'setup') THEN RAISE EXCEPTION '舊庫已有作業／問卷，需另外審查遷移。';END IF;
END$$;

-- 004_v3_expand.sql
-- Pulso V3 / 004: additive expansion only. Does NOT enable V3 or open fieldwork.
-- Preserve migrations 001-003, legacy UUIDs, accounts, survey rows and audit records.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '90s';
DO $$ BEGIN
  IF to_regprocedure('public.submit_response_v2(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'V3_BASELINE_REQUIRED';
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS pulso_v3;
REVOKE ALL ON SCHEMA pulso_v3 FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA pulso_v3 TO service_role;
ALTER TABLE public.settings ADD COLUMN IF NOT EXISTS operation_mode text NOT NULL DEFAULT 'v2'
  CHECK (operation_mode IN ('v2','v3'));
CREATE TABLE pulso_v3.schema_versions (
  version integer PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE pulso_v3.operations (
  id smallint PRIMARY KEY CHECK (id=1),
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120),
  contest text NOT NULL CHECK (char_length(contest) BETWEEN 1 AND 120),
  fieldwork_date date NOT NULL,
  phase text NOT NULL DEFAULT 'setup' CHECK (phase IN ('setup','running','paused','closed')),
  revision bigint NOT NULL DEFAULT 1,
  lease_minutes integer NOT NULL DEFAULT 120 CHECK (lease_minutes BETWEEN 15 AND 240),
  drain_hours integer NOT NULL DEFAULT 24 CHECK (drain_hours BETWEEN 1 AND 72),
  minimum_client integer NOT NULL DEFAULT 30000 CHECK (minimum_client>=30000),
  viewer_enabled boolean NOT NULL DEFAULT false,
  viewer_min_base integer NOT NULL DEFAULT 20 CHECK (viewer_min_base>=20),
  retention_policy text NOT NULL DEFAULT '' CHECK (char_length(retention_policy)<=2000),
  backup_verified_at timestamptz,
  cutover_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO pulso_v3.operations(id,title,contest,fieldwork_date)
 SELECT 1,title,contest,coalesce(fieldwork_date,DATE '2026-10-04') FROM public.settings WHERE id=1;
CREATE SEQUENCE pulso_v3.worker_code_seq;
CREATE TABLE pulso_v3.people (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE DEFAULT ('EN-'||lpad(nextval('pulso_v3.worker_code_seq')::text,6,'0')),
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 100),
  home_district text NOT NULL REFERENCES public.districts(id),
  approval text NOT NULL DEFAULT 'pending' CHECK (approval IN ('pending','approved','suspended','retired')),
  training_passed_at timestamptz, training_version integer,
  training_practice_ack boolean NOT NULL DEFAULT false,
  approved_by uuid, approved_at timestamptz,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  revision bigint NOT NULL DEFAULT 1,
  legacy_profile_id uuid UNIQUE,
  CHECK ((approval<>'approved') OR (training_passed_at IS NOT NULL AND training_practice_ack AND approved_by IS NOT NULL))
);
CREATE TABLE pulso_v3.actors (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  person_id uuid UNIQUE REFERENCES pulso_v3.people(id),
  code text NOT NULL UNIQUE CHECK (char_length(code) BETWEEN 3 AND 40),
  display_name text NOT NULL CHECK (char_length(display_name)<=100),
  role text NOT NULL CHECK (role IN ('admin','coordinator','interviewer','viewer')),
  active boolean NOT NULL DEFAULT true,
  enrolled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  revision bigint NOT NULL DEFAULT 1,
  CHECK ((role='interviewer')=(person_id IS NOT NULL))
);
CREATE TABLE pulso_v3.stations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), district_id text NOT NULL REFERENCES public.districts(id),
  code text NOT NULL UNIQUE CHECK (char_length(code) BETWEEN 2 AND 60 AND code=upper(btrim(code))),
  official_code text NOT NULL DEFAULT '' CHECK (char_length(official_code)<=100),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 160),
  address text NOT NULL CHECK (char_length(btrim(address)) BETWEEN 5 AND 250),
  verified boolean NOT NULL DEFAULT false, revision bigint NOT NULL DEFAULT 1,
  legacy_station_id uuid UNIQUE, UNIQUE(id,district_id)
);
CREATE TABLE pulso_v3.points (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), station_id uuid NOT NULL REFERENCES pulso_v3.stations(id),
  code text NOT NULL UNIQUE CHECK (char_length(code) BETWEEN 2 AND 60 AND code=upper(btrim(code))),
  label text NOT NULL CHECK (char_length(btrim(label)) BETWEEN 2 AND 150),
  planned boolean NOT NULL DEFAULT true,
  latitude double precision CHECK (latitude BETWEEN -90 AND 90),
  longitude double precision CHECK (longitude BETWEEN -180 AND 180),
  state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','approved','open','paused','closed')),
  approved_by uuid, approved_at timestamptz,
  revision bigint NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK ((latitude IS NULL)=(longitude IS NULL)),
  CHECK (state='draft' OR approved_by IS NOT NULL)
);
ALTER TABLE pulso_v3.people ADD COLUMN recruit_point uuid REFERENCES pulso_v3.points(id);
CREATE TABLE pulso_v3.role_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
  district_id text NOT NULL REFERENCES public.districts(id), point_id uuid REFERENCES pulso_v3.points(id),
  capabilities text[] NOT NULL CHECK (cardinality(capabilities)>0 AND capabilities <@ ARRAY['recruit','assign','manage_points','control_points','operations','view_results']::text[]),
  issued_by uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
  valid_from timestamptz NOT NULL DEFAULT clock_timestamp(), valid_until timestamptz NOT NULL,
  revoked_at timestamptz, revision bigint NOT NULL DEFAULT 1,
  CHECK (valid_until>valid_from)
);
CREATE INDEX v3_grants_subject ON pulso_v3.role_grants(user_id,district_id) WHERE revoked_at IS NULL;
CREATE TABLE pulso_v3.questionnaires (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), district_id text NOT NULL REFERENCES public.districts(id),
  version integer NOT NULL CHECK (version>0), contest text NOT NULL CHECK (char_length(contest) BETWEEN 1 AND 120),
  methodology text NOT NULL DEFAULT '' CHECK (char_length(methodology)<=4000),
  sample_interval integer NOT NULL DEFAULT 5 CHECK (sample_interval BETWEEN 1 AND 100),
  items jsonb NOT NULL CHECK (jsonb_typeof(items)='array' AND jsonb_array_length(items) BETWEEN 2 AND 12),
  state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','published','superseded')),
  verified_reference text NOT NULL DEFAULT '' CHECK (char_length(verified_reference)<=1000),
  created_by uuid, published_by uuid, published_at timestamptz,
  revision bigint NOT NULL DEFAULT 1, UNIQUE(district_id,version), UNIQUE(id,district_id),
  CHECK (state='draft' OR (published_by IS NOT NULL AND published_at IS NOT NULL))
);
CREATE UNIQUE INDEX v3_one_published_questionnaire ON pulso_v3.questionnaires(district_id) WHERE state='published';
CREATE TABLE pulso_v3.district_settings (
  district_id text PRIMARY KEY REFERENCES public.districts(id), staffing_target integer NOT NULL DEFAULT 15 CHECK (staffing_target BETWEEN 0 AND 10000),
  enabled boolean NOT NULL DEFAULT true, revision bigint NOT NULL DEFAULT 1
);
INSERT INTO pulso_v3.district_settings(district_id) SELECT id FROM public.districts;
CREATE TABLE pulso_v3.assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), person_id uuid NOT NULL REFERENCES pulso_v3.people(id),
  point_id uuid NOT NULL REFERENCES pulso_v3.points(id), questionnaire_id uuid NOT NULL REFERENCES pulso_v3.questionnaires(id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','acknowledged','active','draining','ended')),
  created_by uuid NOT NULL REFERENCES pulso_v3.actors(user_id), created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  acknowledged_at timestamptz, started_at timestamptz, ended_at timestamptz, drain_until timestamptz,
  active_session_id uuid, reason text NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 500),
  revision bigint NOT NULL DEFAULT 1,
  CHECK (status NOT IN ('active','draining','ended') OR (started_at IS NOT NULL OR status='ended')),
  CHECK (status<>'active' OR (acknowledged_at IS NOT NULL AND active_session_id IS NOT NULL)),
  CHECK (drain_until IS NULL OR (ended_at IS NOT NULL AND drain_until>=ended_at))
);
CREATE UNIQUE INDEX v3_one_active_task ON pulso_v3.assignments(person_id) WHERE status='active';
CREATE INDEX v3_task_person ON pulso_v3.assignments(person_id,created_at DESC);
CREATE TABLE pulso_v3.capture_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), assignment_id uuid NOT NULL REFERENCES pulso_v3.assignments(id),
  user_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id), auth_session_id uuid NOT NULL,
  device_id uuid NOT NULL, issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  capture_until timestamptz NOT NULL, upload_until timestamptz NOT NULL,
  revoked_at timestamptz, revoked_reason text,
  CHECK (capture_until>issued_at AND upload_until>=capture_until)
);
CREATE INDEX v3_grants_assignment ON pulso_v3.capture_grants(assignment_id);
CREATE TABLE pulso_v3.point_windows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), point_id uuid NOT NULL REFERENCES pulso_v3.points(id),
  opened_at timestamptz NOT NULL DEFAULT clock_timestamp(), closed_at timestamptz,
  opened_by uuid NOT NULL REFERENCES pulso_v3.actors(user_id), closed_by uuid,
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 500), CHECK (closed_at IS NULL OR closed_at>=opened_at)
);
CREATE UNIQUE INDEX v3_one_open_window ON pulso_v3.point_windows(point_id) WHERE closed_at IS NULL;
-- Reauthentication never rewrites an original event or grant. Recovery is upload-only and reviewed.
CREATE TABLE pulso_v3.upload_recoveries (
 grant_id uuid NOT NULL REFERENCES pulso_v3.capture_grants(id),
 user_id uuid NOT NULL REFERENCES auth.users(id),auth_session_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(grant_id,auth_session_id)
);
CREATE TABLE pulso_v3.responses (
  id uuid PRIMARY KEY, receipt_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  assignment_id uuid NOT NULL REFERENCES pulso_v3.assignments(id), person_id uuid NOT NULL REFERENCES pulso_v3.people(id),
  point_id uuid NOT NULL REFERENCES pulso_v3.points(id), district_id text NOT NULL REFERENCES public.districts(id),
  questionnaire_id uuid NOT NULL REFERENCES pulso_v3.questionnaires(id), grant_id uuid REFERENCES pulso_v3.capture_grants(id),
  candidate_id uuid, outcome text NOT NULL CHECK (outcome IN ('candidate','blank','invalid','undisclosed','refused')),
  consent boolean NOT NULL, already_voted boolean NOT NULL CHECK (already_voted),
  started_at timestamptz NOT NULL, captured_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  source text NOT NULL CHECK (source IN ('digital','paper')),
  time_precision text NOT NULL DEFAULT 'seconds' CHECK (time_precision IN ('seconds','minutes','interval')),
  paper_batch text, paper_number text,
  submitted_by uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
  payload jsonb NOT NULL, payload_hash text NOT NULL CHECK (length(payload_hash)=64),
  disposition text NOT NULL CHECK (disposition IN ('accepted','pending_review','excluded')),
  reason_code text NOT NULL DEFAULT '', revision bigint NOT NULL DEFAULT 1,
  CHECK ((outcome='candidate')=(candidate_id IS NOT NULL)),
  CHECK ((outcome='refused' AND NOT consent) OR (outcome<>'refused' AND consent)),
  CHECK (started_at<=captured_at AND isfinite(started_at) AND isfinite(captured_at)),
  CHECK ((source='digital' AND grant_id IS NOT NULL AND paper_batch IS NULL AND paper_number IS NULL) OR
         (source='paper' AND grant_id IS NULL AND paper_batch IS NOT NULL AND paper_number IS NOT NULL))
);
CREATE UNIQUE INDEX v3_paper_unique ON pulso_v3.responses(paper_batch,paper_number) WHERE source='paper';
CREATE INDEX v3_response_scope ON pulso_v3.responses(district_id,questionnaire_id,received_at) WHERE disposition='accepted';
CREATE INDEX v3_response_assignment ON pulso_v3.responses(assignment_id,received_at);
CREATE TABLE pulso_v3.reviews (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, response_id uuid NOT NULL REFERENCES pulso_v3.responses(id),
  actor_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id), decision text NOT NULL CHECK (decision IN ('accepted','excluded')),
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 10 AND 1000),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE pulso_v3.audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, actor_id uuid,
  action text NOT NULL CHECK (length(action)<=80), subject_id uuid, request_id uuid,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE pulso_v3.command_receipts (
  actor_id uuid NOT NULL, request_id uuid NOT NULL, action text NOT NULL, payload_hash text NOT NULL,
  scope_district text, scope_point uuid, capability text NOT NULL, result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(actor_id,request_id)
);
CREATE TABLE pulso_v3.enrollments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), person_id uuid NOT NULL REFERENCES pulso_v3.people(id),
  creator_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id), point_id uuid REFERENCES pulso_v3.points(id),
  token_hash text NOT NULL UNIQUE CHECK (length(token_hash)=64), expires_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','claimed','auth_created','ready','completed','revoked')),
  claim_hash text, auth_user_id uuid REFERENCES auth.users(id), claim_at timestamptz, ready_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), request_id uuid NOT NULL,
  revision bigint NOT NULL DEFAULT 1, UNIQUE(creator_id,request_id),
  CHECK (status IN ('issued','revoked') OR claim_hash IS NOT NULL)
);
CREATE UNIQUE INDEX v3_enrollment_person_open ON pulso_v3.enrollments(person_id) WHERE status IN ('issued','claimed','auth_created','ready');
CREATE TABLE pulso_v3.provision_requests (
  enrollment_id uuid PRIMARY KEY REFERENCES pulso_v3.enrollments(id),
  stage text NOT NULL DEFAULT 'preparing' CHECK (stage IN ('preparing','auth_created','profile_ready','completed','failed')),
  auth_user_id uuid, error_code text, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lock_id uuid, lock_until timestamptz
);
CREATE TABLE pulso_v3.rate_limits (
  bucket text PRIMARY KEY, window_start timestamptz NOT NULL, attempts integer NOT NULL
);
CREATE TABLE pulso_v3.viewer_snapshots (
  district_id text PRIMARY KEY REFERENCES public.districts(id), payload jsonb NOT NULL,
  published_at timestamptz NOT NULL, published_by uuid NOT NULL REFERENCES pulso_v3.actors(user_id)
);
CREATE TABLE pulso_v3.import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
  format_version text NOT NULL CHECK (format_version='PULSO_R3'), kind text NOT NULL CHECK (kind IN ('stations','points','people','questionnaires','assignments')),
  payload jsonb NOT NULL, batch_hash text NOT NULL, base_revision bigint NOT NULL,
  state text NOT NULL DEFAULT 'preview' CHECK (state IN ('preview','applied')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), applied_at timestamptz
);
CREATE TABLE pulso_v3.attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), point_id uuid NOT NULL REFERENCES pulso_v3.points(id),
  object_path text NOT NULL UNIQUE, file_name text NOT NULL CHECK (char_length(file_name)<=160),
  media_type text NOT NULL CHECK (media_type IN ('application/pdf','image/png','image/jpeg')),
  bytes bigint NOT NULL CHECK (bytes BETWEEN 1 AND 10485760), created_by uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
  purpose text NOT NULL CHECK (purpose IN ('site_authorization','methodology','incident')),
  state text NOT NULL DEFAULT 'reserved' CHECK (state IN ('reserved','uploaded')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE pulso_v3.export_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id),
  kind text NOT NULL, payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL DEFAULT (clock_timestamp()+interval '1 day')
);
CREATE TABLE pulso_v3.legacy_function_backups (
  signature text PRIMARY KEY, definition text NOT NULL, original_oid oid NOT NULL,
  owner_name text NOT NULL, saved_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.v3_signals (
  district_id text PRIMARY KEY REFERENCES public.districts(id), revision bigint NOT NULL DEFAULT 1,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO public.v3_signals(district_id) SELECT id FROM public.districts;
ALTER TABLE public.v3_signals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.v3_signals FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.v3_signals TO authenticated;
GRANT ALL ON TABLE public.v3_signals TO service_role;
-- Copy references, never mutate the original V2 records. Unknown sites remain DRAFT.
INSERT INTO pulso_v3.people(id,code,display_name,home_district,legacy_profile_id)
 SELECT id,code,coalesce(nullif(btrim(display_name),''),code),district_id,id
 FROM public.profiles WHERE role='interviewer';
INSERT INTO pulso_v3.actors(user_id,person_id,code,display_name,role,active,enrolled)
 SELECT id,CASE WHEN role='interviewer' THEN id END,code,coalesce(nullif(display_name,''),code),role,active,true
 FROM public.profiles WHERE role IN ('admin','viewer','interviewer');
INSERT INTO pulso_v3.stations(id,district_id,code,name,address,legacy_station_id)
 SELECT id,district_id,coalesce(nullif(upper(btrim(code)),''),'LEGACY-'||upper(replace(id::text,'-',''))),name,
        coalesce(nullif(btrim(address),''),'PENDIENTE DE VERIFICACIÓN'),id FROM public.stations WHERE active;
INSERT INTO pulso_v3.points(station_id,code,label,planned)
 SELECT id,'PT-'||upper(replace(id::text,'-','')),coalesce(nullif(btrim(point_label),''),'Punto pendiente de verificación'),true
 FROM public.stations WHERE active;
INSERT INTO pulso_v3.questionnaires(district_id,version,contest,methodology,sample_interval,items)
 SELECT d.id,1,o.contest,'',5,
   (SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'list',c.list_label,'order',c.sort_order) ORDER BY c.sort_order)
    FROM public.candidates c WHERE c.district_id=d.id AND c.active)
 FROM public.districts d CROSS JOIN pulso_v3.operations o;
-- Existing viewers retain an initial city grant; results stay globally blocked.
INSERT INTO pulso_v3.role_grants(user_id,district_id,capabilities,issued_by,valid_until)
 SELECT v.user_id,d.id,ARRAY['view_results'],a.user_id,(o.fieldwork_date+interval '2 days')::timestamptz
 FROM pulso_v3.actors v JOIN public.profiles p ON p.id=v.user_id CROSS JOIN public.districts d
 CROSS JOIN pulso_v3.operations o CROSS JOIN LATERAL (SELECT user_id FROM pulso_v3.actors WHERE role='admin' AND active ORDER BY created_at LIMIT 1) a
 WHERE v.role='viewer' AND (p.district_id IS NULL OR p.district_id=d.id);
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='pulso_v3' LOOP
  EXECUTE format('ALTER TABLE pulso_v3.%I ENABLE ROW LEVEL SECURITY',t.tablename);
 END LOOP;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA pulso_v3 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA pulso_v3 FROM PUBLIC,anon,authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA pulso_v3 TO service_role;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA pulso_v3 TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA pulso_v3 REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
INSERT INTO pulso_v3.schema_versions(version) VALUES(4);

-- 005_v3_api.sql
-- Pulso V3 / 005: scope-checked RPCs. Private tables have no browser grants.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
CREATE FUNCTION pulso_v3.actor() RETURNS pulso_v3.actors
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; sid uuid;
BEGIN
 sid:=nullif(auth.jwt()->>'session_id','')::uuid;
 IF auth.uid() IS NULL OR sid IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=sid AND user_id=auth.uid()) THEN
  RAISE EXCEPTION 'V3_SESSION_REQUIRED' USING ERRCODE='42501';
 END IF;
 SELECT * INTO a FROM pulso_v3.actors WHERE user_id=auth.uid() AND active;
 IF a.user_id IS NULL THEN RAISE EXCEPTION 'V3_ACCOUNT_DISABLED' USING ERRCODE='42501'; END IF;
 RETURN a;
END $$;
CREATE FUNCTION pulso_v3.can(u uuid,cap text,d text,p uuid DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM pulso_v3.actors a WHERE a.user_id=u AND a.active AND
 (a.role='admin' OR (a.role IN ('coordinator','viewer') AND EXISTS(
  SELECT 1 FROM pulso_v3.role_grants g WHERE g.user_id=u AND g.district_id=d
   AND (g.point_id IS NULL OR g.point_id=p) AND cap=ANY(g.capabilities)
   AND g.revoked_at IS NULL AND g.valid_from<=statement_timestamp() AND g.valid_until>statement_timestamp()
   AND ((a.role='viewer' AND cap='view_results') OR (a.role='coordinator' AND cap<>'view_results'))))))
$$;
CREATE FUNCTION pulso_v3.require_cap(u uuid,cap text,d text,p uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN
 IF NOT pulso_v3.can(u,cap,d,p) THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501'; END IF;
END $$;
CREATE FUNCTION pulso_v3.require_revision(actual bigint,wanted bigint) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$ BEGIN
 IF wanted IS NULL OR actual IS DISTINCT FROM wanted THEN RAISE EXCEPTION 'V3_RELOAD_REQUIRED' USING ERRCODE='40001'; END IF;
END $$;
CREATE FUNCTION pulso_v3.hash(j jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT encode(sha256(convert_to(j::text,'UTF8')),'hex')
$$;
CREATE FUNCTION pulso_v3.signal(d text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 UPDATE public.v3_signals SET revision=revision+1,changed_at=clock_timestamp()
 WHERE district_id IN(SELECT id FROM public.districts WHERE d IS NULL OR id=d)
$$;
CREATE FUNCTION pulso_v3.log(u uuid,act text,sub uuid,req uuid,detail jsonb DEFAULT '{}'::jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO pulso_v3.audit(actor_id,action,subject_id,request_id,detail) VALUES(u,act,sub,req,detail)
$$;
CREATE FUNCTION pulso_v3.immutable_guard() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'V3_IMMUTABLE_RECORD'; END IF;
 IF TG_TABLE_NAME='responses' THEN
  IF (to_jsonb(NEW)-ARRAY['disposition','reason_code','revision']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['disposition','reason_code','revision']) THEN RAISE EXCEPTION 'V3_IMMUTABLE_RESPONSE'; END IF;
 ELSIF TG_TABLE_NAME='questionnaires' THEN
  IF OLD.state<>'draft' AND (to_jsonb(NEW)-ARRAY['state','revision']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','revision']) THEN RAISE EXCEPTION 'V3_IMMUTABLE_QUESTIONNAIRE'; END IF;
 ELSIF TG_TABLE_NAME='audit' THEN RAISE EXCEPTION 'V3_IMMUTABLE_AUDIT';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER v3_response_immutable BEFORE UPDATE OR DELETE ON pulso_v3.responses FOR EACH ROW EXECUTE FUNCTION pulso_v3.immutable_guard();
CREATE TRIGGER v3_questionnaire_immutable BEFORE UPDATE OR DELETE ON pulso_v3.questionnaires FOR EACH ROW EXECUTE FUNCTION pulso_v3.immutable_guard();
CREATE TRIGGER v3_audit_immutable BEFORE UPDATE OR DELETE ON pulso_v3.audit FOR EACH ROW EXECUTE FUNCTION pulso_v3.immutable_guard();
CREATE FUNCTION pulso_v3.validate_items(items jsonb) RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE item jsonb; ids uuid[]:='{}'; names text[]:='{}'; cid uuid; nm text;
BEGIN
 IF jsonb_typeof(items) IS DISTINCT FROM 'array' OR jsonb_array_length(items) NOT BETWEEN 2 AND 12 THEN RAISE EXCEPTION 'V3_CANDIDATES_REQUIRED'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(items) LOOP
  cid:=(item->>'id')::uuid; nm:=lower(btrim(coalesce(item->>'name','')));
  IF cid IS NULL OR cid=ANY(ids) OR nm=ANY(names) OR char_length(nm) NOT BETWEEN 1 AND 100
     OR char_length(btrim(coalesce(item->>'list',''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'V3_INVALID_CANDIDATE'; END IF;
  ids:=array_append(ids,cid);names:=array_append(names,nm);
 END LOOP;
END $$;
CREATE FUNCTION public.v3_can_read_signal(p_district text) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;
BEGIN
 a:=pulso_v3.actor();
 IF a.role='viewer' THEN RETURN false; END IF;
 RETURN a.role='admin' OR pulso_v3.can(a.user_id,'operations',p_district,NULL)
 OR EXISTS(SELECT 1 FROM pulso_v3.role_grants g WHERE g.user_id=a.user_id AND g.district_id=p_district AND g.revoked_at IS NULL AND g.valid_from<=statement_timestamp() AND g.valid_until>statement_timestamp() AND 'operations'=ANY(g.capabilities))
 OR EXISTS(SELECT 1 FROM pulso_v3.assignments t JOIN pulso_v3.points p ON p.id=t.point_id JOIN pulso_v3.stations s ON s.id=p.station_id WHERE t.person_id=a.person_id AND t.status IN('pending','acknowledged','active','draining') AND s.district_id=p_district);
EXCEPTION WHEN insufficient_privilege THEN RETURN false;
END $$;
CREATE POLICY v3_signal_read ON public.v3_signals FOR SELECT TO authenticated USING(public.v3_can_read_signal(district_id));
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime') AND NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='v3_signals') THEN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.v3_signals;
 END IF;
END $$;

-- One command = one transaction. Idempotency keys never contain passwords or invite tokens.
CREATE FUNCTION public.v3_command(p_action text,p_data jsonb,p_request_id uuid,p_expected bigint DEFAULT 0,p_client integer DEFAULT 30000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
DECLARE a pulso_v3.actors; o pulso_v3.operations; st pulso_v3.stations; pt pulso_v3.points;
 per pulso_v3.people; t pulso_v3.assignments; q pulso_v3.questionnaires; g pulso_v3.role_grants;
 other pulso_v3.actors; resp pulso_v3.responses; old pulso_v3.command_receipts;
 id uuid; d text; point uuid; cap text:='admin'; h text; result jsonb; items jsonb; reason text;
 act text; state text; now_at timestamptz:=clock_timestamp(); sid uuid; n integer; prior_scope record;
BEGIN
 a:=pulso_v3.actor(); SELECT * INTO o FROM pulso_v3.operations WHERE operations.id=1 FOR UPDATE;
 IF p_client IS NULL OR p_client<o.minimum_client THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED'; END IF;
 IF p_request_id IS NULL OR jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>100000 THEN RAISE EXCEPTION 'V3_INVALID_COMMAND'; END IF;
 reason:=btrim(coalesce(p_data->>'reason',''));
 id:=nullif(p_data->>'id','')::uuid;
 -- Derive scope from stored resources, never from a caller's replacement district.
 IF p_action IN('station.save') THEN
  IF id IS NOT NULL THEN SELECT * INTO st FROM pulso_v3.stations WHERE stations.id=id; IF st.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;d:=st.district_id; ELSE d:=p_data->>'district_id'; END IF;cap:='manage_points';
 ELSIF p_action IN('point.save','point.approve','point.state','attachment.reserve') THEN
  IF id IS NOT NULL THEN SELECT * INTO pt FROM pulso_v3.points WHERE points.id=id; IF pt.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;point:=id;SELECT * INTO st FROM pulso_v3.stations WHERE stations.id=pt.station_id;
  ELSE SELECT * INTO st FROM pulso_v3.stations WHERE stations.id=(p_data->>'station_id')::uuid;IF st.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;END IF;
  d:=st.district_id; cap:=CASE WHEN p_action='point.state' THEN 'control_points' ELSE 'manage_points' END;
 ELSIF p_action IN('person.add','person.approve','person.suspend','person.restore') THEN
  IF id IS NOT NULL THEN SELECT * INTO per FROM pulso_v3.people WHERE people.id=id;IF per.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;d:=per.home_district;point:=per.recruit_point;
  ELSE d:=p_data->>'district_id';point:=nullif(p_data->>'point_id','')::uuid;END IF;cap:='recruit';
 ELSIF p_action='assignment.create' THEN
  point:=(p_data->>'point_id')::uuid;SELECT * INTO pt FROM pulso_v3.points WHERE points.id=point;
  SELECT * INTO st FROM pulso_v3.stations WHERE stations.id=pt.station_id;d:=st.district_id;cap:='assign';
 ELSIF p_action IN('assignment.finish','assignment.revoke_device') THEN
  SELECT * INTO t FROM pulso_v3.assignments WHERE assignments.id=id;IF t.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
  point:=t.point_id;SELECT * INTO pt FROM pulso_v3.points WHERE points.id=point;SELECT * INTO st FROM pulso_v3.stations WHERE stations.id=pt.station_id;d:=st.district_id;cap:='assign';
 ELSIF p_action IN('actor.disable','actor.enable') THEN
  SELECT * INTO other FROM pulso_v3.actors WHERE user_id=id;IF other.user_id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
  IF other.role='interviewer' THEN SELECT * INTO per FROM pulso_v3.people WHERE people.id=other.person_id;d:=per.home_district;point:=per.recruit_point;cap:='recruit'; END IF;
 ELSIF p_action IN('questionnaire.save','questionnaire.publish','viewer.publish','district.target') THEN
  d:=p_data->>'district_id';
  IF p_action='questionnaire.publish' THEN SELECT * INTO q FROM pulso_v3.questionnaires WHERE questionnaires.id=id;IF q.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;d:=q.district_id;END IF;
 ELSIF p_action='paper.submit' THEN
  SELECT * INTO t FROM pulso_v3.assignments WHERE assignments.id=(p_data->>'assignment_id')::uuid;IF t.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;point:=t.point_id;
  SELECT * INTO pt FROM pulso_v3.points WHERE points.id=point;SELECT * INTO st FROM pulso_v3.stations WHERE stations.id=pt.station_id;d:=st.district_id;cap:='operations';
 ELSIF p_action NOT IN('operation.save','operation.state','viewer.access','actor.promote','grant.save','grant.revoke','review.decide','export.create') THEN RAISE EXCEPTION 'V3_UNKNOWN_COMMAND';
 END IF;
 IF cap='admin' AND a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501'; END IF;
 IF cap<>'admin' THEN PERFORM pulso_v3.require_cap(a.user_id,cap,d,point); END IF;
 h:=pulso_v3.hash(jsonb_build_object('action',p_action,'data',p_data,'expected',p_expected));
 PERFORM pg_advisory_xact_lock(hashtextextended(a.user_id::text||p_request_id::text,3));
 SELECT * INTO old FROM pulso_v3.command_receipts WHERE actor_id=a.user_id AND request_id=p_request_id;
 IF FOUND THEN
  IF old.payload_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT' USING ERRCODE='23514'; END IF;
  RETURN old.result||jsonb_build_object('duplicate',true);
 END IF;
 result:='{}'::jsonb;
 CASE p_action
 WHEN 'operation.save' THEN
  PERFORM pulso_v3.require_revision(o.revision,p_expected);
  IF (p_data->>'fieldwork_date')::date IS DISTINCT FROM o.fieldwork_date AND EXISTS(SELECT 1 FROM pulso_v3.point_windows) THEN RAISE EXCEPTION 'V3_DATE_LOCKED'; END IF;
  UPDATE pulso_v3.operations SET title=btrim(p_data->>'title'),contest=btrim(p_data->>'contest'),fieldwork_date=(p_data->>'fieldwork_date')::date,
   retention_policy=btrim(coalesce(p_data->>'retention_policy','')),lease_minutes=coalesce((p_data->>'lease_minutes')::integer,lease_minutes),
   drain_hours=coalesce((p_data->>'drain_hours')::integer,drain_hours),revision=revision+1,updated_at=now_at WHERE operations.id=1;
  result:=jsonb_build_object('revision',o.revision+1);
 WHEN 'operation.state' THEN
  PERFORM pulso_v3.require_revision(o.revision,p_expected);state:=p_data->>'state';
  IF length(reason)<5 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  IF state='running' THEN
   IF (SELECT operation_mode FROM public.settings WHERE settings.id=1)<>'v3' THEN RAISE EXCEPTION 'V3_NOT_ACTIVATED'; END IF;
   IF o.phase NOT IN('setup','paused') OR o.fieldwork_date<>(now_at AT TIME ZONE 'America/Asuncion')::date OR length(o.retention_policy)<10 THEN RAISE EXCEPTION 'V3_OPERATION_NOT_READY'; END IF;
  ELSIF state NOT IN('paused','closed') OR o.phase NOT IN('running','paused') THEN RAISE EXCEPTION 'V3_BAD_TRANSITION'; END IF;
  UPDATE pulso_v3.operations SET phase=state,revision=revision+1,updated_at=now_at WHERE operations.id=1;
  IF state IN('paused','closed') THEN
   UPDATE pulso_v3.point_windows SET closed_at=now_at,closed_by=a.user_id WHERE closed_at IS NULL;
   UPDATE pulso_v3.points SET state='paused',revision=revision+1 WHERE points.state='open';
  END IF;
  result:=jsonb_build_object('state',state,'revision',o.revision+1);
 WHEN 'district.target' THEN
  IF NOT EXISTS(SELECT 1 FROM public.districts WHERE districts.id=d) THEN RAISE EXCEPTION 'V3_BAD_DISTRICT'; END IF;
  SELECT revision INTO n FROM pulso_v3.district_settings WHERE district_id=d;PERFORM pulso_v3.require_revision(n,p_expected);
  UPDATE pulso_v3.district_settings SET staffing_target=(p_data->>'target')::integer,revision=revision+1 WHERE district_id=d;
 WHEN 'station.save' THEN
  IF id IS NULL THEN
   id:=gen_random_uuid();INSERT INTO pulso_v3.stations(id,district_id,code,official_code,name,address,verified)
    VALUES(id,d,upper(btrim(p_data->>'code')),btrim(coalesce(p_data->>'official_code','')),btrim(p_data->>'name'),btrim(p_data->>'address'),false);
  ELSE
   PERFORM pulso_v3.require_revision(st.revision,p_expected);
   IF EXISTS(SELECT 1 FROM pulso_v3.points p JOIN pulso_v3.point_windows w ON w.point_id=p.id WHERE p.station_id=id) THEN RAISE EXCEPTION 'V3_SITE_HISTORY_LOCKED'; END IF;
   UPDATE pulso_v3.stations SET code=upper(btrim(p_data->>'code')),official_code=btrim(coalesce(p_data->>'official_code','')),name=btrim(p_data->>'name'),address=btrim(p_data->>'address'),verified=false,revision=revision+1 WHERE stations.id=id;
  END IF;result:=jsonb_build_object('id',id);
 WHEN 'point.save' THEN
  IF id IS NULL THEN
   id:=gen_random_uuid();INSERT INTO pulso_v3.points(id,station_id,code,label,planned,latitude,longitude)
    VALUES(id,st.id,upper(btrim(p_data->>'code')),btrim(p_data->>'label'),coalesce((p_data->>'planned')::boolean,true),nullif(p_data->>'latitude','')::double precision,nullif(p_data->>'longitude','')::double precision);
  ELSE
   PERFORM pulso_v3.require_revision(pt.revision,p_expected);
   IF EXISTS(SELECT 1 FROM pulso_v3.point_windows WHERE point_id=id) THEN RAISE EXCEPTION 'V3_POINT_HISTORY_LOCKED'; END IF;
   UPDATE pulso_v3.points SET code=upper(btrim(p_data->>'code')),label=btrim(p_data->>'label'),latitude=nullif(p_data->>'latitude','')::double precision,
    longitude=nullif(p_data->>'longitude','')::double precision,state='draft',approved_by=NULL,approved_at=NULL,revision=revision+1 WHERE points.id=id;
  END IF;result:=jsonb_build_object('id',id);
 WHEN 'point.approve' THEN
  PERFORM pulso_v3.require_revision(pt.revision,p_expected);
  IF pt.state NOT IN('draft','approved') OR (p_data->>'verified')::boolean IS DISTINCT FROM true OR length(reason)<10
    OR st.name~*'(práctica|ejemplo|NO OFICIAL|pendiente)' OR st.address~*'(PENDIENTE|ejemplo)' OR pt.label~*'(pendiente|ejemplo)' THEN RAISE EXCEPTION 'V3_VERIFY_REAL_SITE'; END IF;
  UPDATE pulso_v3.stations SET verified=true,revision=revision+1 WHERE stations.id=st.id;
  UPDATE pulso_v3.points SET state='approved',approved_by=a.user_id,approved_at=now_at,revision=revision+1 WHERE points.id=id;
 WHEN 'point.state' THEN
  PERFORM pulso_v3.require_revision(pt.revision,p_expected);state:=p_data->>'state';
  IF length(reason)<5 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  IF state='open' THEN
   IF o.phase<>'running' OR o.fieldwork_date<>(now_at AT TIME ZONE 'America/Asuncion')::date OR pt.state NOT IN('approved','paused') OR NOT st.verified
    OR NOT EXISTS(SELECT 1 FROM pulso_v3.questionnaires WHERE district_id=d AND questionnaires.state='published') THEN RAISE EXCEPTION 'V3_POINT_NOT_READY'; END IF;
   IF NOT EXISTS(SELECT 1 FROM pulso_v3.assignments x JOIN pulso_v3.people w ON w.id=x.person_id
     WHERE x.point_id=id AND x.status IN('acknowledged','active') AND w.approval='approved') THEN RAISE EXCEPTION 'V3_POINT_NEEDS_ONE_READY_WORKER'; END IF;
   INSERT INTO pulso_v3.point_windows(point_id,opened_by,reason) VALUES(id,a.user_id,reason);
  ELSIF state IN('paused','closed') AND pt.state IN('open','paused','approved') THEN
   UPDATE pulso_v3.point_windows SET closed_at=now_at,closed_by=a.user_id WHERE point_id=id AND closed_at IS NULL;
  ELSE RAISE EXCEPTION 'V3_BAD_TRANSITION'; END IF;
  UPDATE pulso_v3.points SET state=state,revision=revision+1 WHERE points.id=id; -- resolved below: use local state via alias
  result:=jsonb_build_object('id',id,'state',state,'revision',pt.revision+1);
 WHEN 'person.add' THEN
  IF point IS NOT NULL AND NOT EXISTS(SELECT 1 FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE p.id=point AND s.district_id=d) THEN RAISE EXCEPTION 'V3_POINT_DISTRICT_MISMATCH'; END IF;
  id:=gen_random_uuid();INSERT INTO pulso_v3.people(id,display_name,home_district,recruit_point,created_by)
   VALUES(id,btrim(p_data->>'display_name'),d,point,a.user_id);
  result:=jsonb_build_object('id',id);
 WHEN 'person.approve' THEN
  PERFORM pulso_v3.require_revision(per.revision,p_expected);
  IF per.training_passed_at IS NULL OR NOT per.training_practice_ack OR length(reason)<5 THEN RAISE EXCEPTION 'V3_TRAINING_REQUIRED'; END IF;
  UPDATE pulso_v3.people SET approval='approved',approved_by=a.user_id,approved_at=now_at,revision=revision+1 WHERE people.id=id;
 WHEN 'person.suspend' THEN
  PERFORM pulso_v3.require_revision(per.revision,p_expected);IF length(reason)<5 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  UPDATE pulso_v3.people SET approval='suspended',revision=revision+1 WHERE people.id=id;
  UPDATE pulso_v3.capture_grants cg SET revoked_at=now_at,revoked_reason='PERSON_SUSPENDED' WHERE cg.assignment_id IN(SELECT x.id FROM pulso_v3.assignments x WHERE x.person_id=id) AND cg.revoked_at IS NULL;
 WHEN 'person.restore' THEN
  PERFORM pulso_v3.require_revision(per.revision,p_expected);IF length(reason)<5 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  UPDATE pulso_v3.people SET approval='pending',approved_by=NULL,approved_at=NULL,revision=revision+1 WHERE people.id=id;
 WHEN 'assignment.create' THEN
  SELECT * INTO per FROM pulso_v3.people WHERE people.id=(p_data->>'person_id')::uuid FOR UPDATE;
  IF per.id IS NULL OR pt.id IS NULL OR pt.state='draft' OR pt.state='closed' OR length(reason)<5 THEN RAISE EXCEPTION 'V3_INVALID_ASSIGNMENT'; END IF;
  IF per.home_district<>d THEN PERFORM pulso_v3.require_cap(a.user_id,'assign',per.home_district,per.recruit_point); END IF;
  FOR prior_scope IN SELECT x.point_id,s.district_id FROM pulso_v3.assignments x JOIN pulso_v3.points p ON p.id=x.point_id JOIN pulso_v3.stations s ON s.id=p.station_id WHERE x.person_id=per.id AND x.status IN('pending','acknowledged','active') LOOP
   PERFORM pulso_v3.require_cap(a.user_id,'assign',prior_scope.district_id,prior_scope.point_id);
  END LOOP;
  SELECT * INTO q FROM pulso_v3.questionnaires WHERE district_id=d AND questionnaires.state='published';
  IF q.id IS NULL THEN RAISE EXCEPTION 'V3_QUESTIONNAIRE_NOT_PUBLISHED'; END IF;
  -- Do not finish the current task until the new task is acknowledged by its owner.
  IF EXISTS(SELECT 1 FROM pulso_v3.assignments WHERE person_id=per.id AND status IN('pending','acknowledged')) THEN RAISE EXCEPTION 'V3_PENDING_ASSIGNMENT_EXISTS'; END IF;
  id:=gen_random_uuid();INSERT INTO pulso_v3.assignments(id,person_id,point_id,questionnaire_id,created_by,reason)
   VALUES(id,per.id,point,q.id,a.user_id,reason);result:=jsonb_build_object('id',id);
 WHEN 'assignment.finish' THEN
  PERFORM pulso_v3.require_revision(t.revision,p_expected);IF length(reason)<5 OR t.status NOT IN('pending','acknowledged','active','draining') THEN RAISE EXCEPTION 'V3_BAD_TRANSITION'; END IF;
  UPDATE pulso_v3.assignments SET status=CASE WHEN started_at IS NULL THEN 'ended' ELSE 'draining' END,
   ended_at=coalesce(ended_at,now_at),drain_until=coalesce(drain_until,now_at+make_interval(hours=>o.drain_hours)),revision=revision+1 WHERE assignments.id=id;
 WHEN 'assignment.revoke_device' THEN
  PERFORM pulso_v3.require_revision(t.revision,p_expected);IF length(reason)<5 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  UPDATE pulso_v3.capture_grants SET revoked_at=now_at,revoked_reason='DEVICE_REVOKED' WHERE assignment_id=id AND revoked_at IS NULL;
  UPDATE pulso_v3.assignments SET status=CASE WHEN started_at IS NULL THEN 'ended' ELSE 'draining' END,
   ended_at=coalesce(ended_at,now_at),drain_until=coalesce(drain_until,now_at+make_interval(hours=>o.drain_hours)),active_session_id=NULL,revision=revision+1 WHERE assignments.id=id;
 WHEN 'actor.enable' THEN
  IF id=a.user_id OR other.role='admin' THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;
  PERFORM pulso_v3.require_revision(other.revision,p_expected);IF length(reason)<10 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED';END IF;
  -- Old sessions are not restored: a new login is required after reactivation.
  INSERT INTO pulso_v3.revoked_sessions(session_id,user_id,reason) SELECT ss.id,ss.user_id,'ACCOUNT_REENABLED_RELOGIN' FROM auth.sessions ss WHERE ss.user_id=other.user_id ON CONFLICT(session_id) DO NOTHING;
  UPDATE pulso_v3.actors SET active=true,revision=revision+1 WHERE user_id=id;
 WHEN 'actor.disable' THEN
  IF id=a.user_id OR other.role='admin' THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;
  PERFORM pulso_v3.require_revision(other.revision,p_expected);
  UPDATE pulso_v3.actors SET active=false,revision=revision+1 WHERE user_id=id;
  UPDATE pulso_v3.capture_grants SET revoked_at=now_at,revoked_reason='ACCOUNT_DISABLED' WHERE user_id=id AND revoked_at IS NULL;
 WHEN 'actor.promote' THEN
  -- Only existing verified Auth identities can receive elevated roles. Enrollment cannot self-promote.
  SELECT * INTO other FROM pulso_v3.actors WHERE user_id=id;IF other.user_id IS NULL OR other.role='interviewer' OR id=a.user_id THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;
  PERFORM pulso_v3.require_revision(other.revision,p_expected);state:=p_data->>'role';
  IF state NOT IN('viewer','coordinator','admin') OR length(reason)<10 THEN RAISE EXCEPTION 'V3_INVALID_ROLE'; END IF;
  UPDATE pulso_v3.actors SET role=state,revision=revision+1 WHERE user_id=id;
 WHEN 'grant.save' THEN
  SELECT * INTO other FROM pulso_v3.actors WHERE user_id=(p_data->>'user_id')::uuid;
  d:=p_data->>'district_id';point:=nullif(p_data->>'point_id','')::uuid;
  IF other.role NOT IN('coordinator','viewer') THEN RAISE EXCEPTION 'V3_INVALID_GRANTEE'; END IF;
  IF other.role='viewer' AND (p_data->'capabilities'<> '["view_results"]'::jsonb OR point IS NOT NULL) THEN RAISE EXCEPTION 'V3_VIEWER_CITY_SCOPE_ONLY'; END IF;
  IF other.role='coordinator' AND (p_data->'capabilities')?'view_results' THEN RAISE EXCEPTION 'V3_COORDINATOR_NO_PREFERENCES'; END IF;
  IF point IS NOT NULL AND NOT EXISTS(SELECT 1 FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE p.id=point AND s.district_id=d) THEN RAISE EXCEPTION 'V3_POINT_DISTRICT_MISMATCH'; END IF;
  IF id IS NULL THEN id:=gen_random_uuid();INSERT INTO pulso_v3.role_grants(id,user_id,district_id,point_id,capabilities,issued_by,valid_until)
   VALUES(id,other.user_id,d,point,ARRAY(SELECT jsonb_array_elements_text(p_data->'capabilities')),a.user_id,(p_data->>'valid_until')::timestamptz);
  ELSE RAISE EXCEPTION 'V3_GRANT_REPLACE_REQUIRES_REVOKE'; END IF;result:=jsonb_build_object('id',id);
 WHEN 'grant.revoke' THEN
  SELECT * INTO g FROM pulso_v3.role_grants WHERE role_grants.id=id;IF g.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
  PERFORM pulso_v3.require_revision(g.revision,p_expected);d:=g.district_id;
  UPDATE pulso_v3.role_grants SET revoked_at=now_at,revision=revision+1 WHERE role_grants.id=id;
 WHEN 'questionnaire.save' THEN
  items:=p_data->'items';PERFORM pulso_v3.validate_items(items);
  IF id IS NULL THEN
   SELECT coalesce(max(version),0)+1 INTO n FROM pulso_v3.questionnaires WHERE district_id=d;
   id:=gen_random_uuid();INSERT INTO pulso_v3.questionnaires(id,district_id,version,contest,methodology,sample_interval,items,created_by,verified_reference)
    VALUES(id,d,n,btrim(p_data->>'contest'),btrim(coalesce(p_data->>'methodology','')),(p_data->>'sample_interval')::integer,items,a.user_id,btrim(coalesce(p_data->>'reference','')));
  ELSE
   SELECT * INTO q FROM pulso_v3.questionnaires WHERE questionnaires.id=id;IF q.id IS NULL OR q.district_id IS DISTINCT FROM d OR q.state<>'draft' THEN RAISE EXCEPTION 'V3_QUESTIONNAIRE_LOCKED'; END IF;
   PERFORM pulso_v3.require_revision(q.revision,p_expected);
   UPDATE pulso_v3.questionnaires SET contest=btrim(p_data->>'contest'),methodology=btrim(coalesce(p_data->>'methodology','')),sample_interval=(p_data->>'sample_interval')::integer,
    items=items,verified_reference=btrim(coalesce(p_data->>'reference','')),revision=revision+1 WHERE questionnaires.id=id;
  END IF;result:=jsonb_build_object('id',id);
 WHEN 'questionnaire.publish' THEN
  PERFORM pulso_v3.require_revision(q.revision,p_expected);PERFORM pulso_v3.validate_items(q.items);
  IF q.state<>'draft' OR char_length(q.methodology)<20 OR char_length(q.verified_reference)<5 OR (p_data->>'confirmed')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'V3_QUESTIONNAIRE_UNVERIFIED'; END IF;
  UPDATE pulso_v3.questionnaires SET state='superseded',revision=revision+1 WHERE district_id=d AND questionnaires.state='published';
  UPDATE pulso_v3.questionnaires SET state='published',published_by=a.user_id,published_at=now_at,revision=revision+1 WHERE questionnaires.id=id;
  UPDATE pulso_v3.point_windows SET closed_at=now_at,closed_by=a.user_id WHERE closed_at IS NULL AND point_id IN(SELECT p.id FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE s.district_id=d);
  UPDATE pulso_v3.points SET state='paused',revision=revision+1 WHERE points.state='open' AND station_id IN(SELECT s.id FROM pulso_v3.stations s WHERE s.district_id=d);
  UPDATE pulso_v3.assignments SET status=CASE WHEN started_at IS NULL THEN 'ended' ELSE 'draining' END,ended_at=coalesce(ended_at,now_at),
   drain_until=coalesce(drain_until,now_at+make_interval(hours=>o.drain_hours)),revision=revision+1
   WHERE status IN('pending','acknowledged','active') AND questionnaire_id IN(SELECT x.id FROM pulso_v3.questionnaires x WHERE x.district_id=d AND x.id<>id);
  DELETE FROM pulso_v3.viewer_snapshots WHERE district_id=d;
 WHEN 'viewer.access' THEN
  PERFORM pulso_v3.require_revision(o.revision,p_expected);IF length(reason)<10 OR p_data->>'enabled' IS NULL THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  UPDATE pulso_v3.operations SET viewer_enabled=(p_data->>'enabled')::boolean,revision=revision+1 WHERE operations.id=1;
 WHEN 'review.decide' THEN
  SELECT * INTO resp FROM pulso_v3.responses WHERE responses.id=id FOR UPDATE;
  IF resp.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
  IF resp.submitted_by=a.user_id THEN RAISE EXCEPTION 'V3_INDEPENDENT_REVIEW_REQUIRED'; END IF;
  PERFORM pulso_v3.require_revision(resp.revision,p_expected);state:=p_data->>'decision';d:=resp.district_id;
  IF state NOT IN('accepted','excluded') OR length(reason)<10 THEN RAISE EXCEPTION 'V3_REVIEW_REASON_REQUIRED'; END IF;
  INSERT INTO pulso_v3.reviews(response_id,actor_id,decision,reason) VALUES(id,a.user_id,state,reason);
  UPDATE pulso_v3.responses SET disposition=state,reason_code='REVIEWED',revision=revision+1 WHERE responses.id=id;
  DELETE FROM pulso_v3.viewer_snapshots WHERE district_id=d;
 WHEN 'paper.submit' THEN
  IF length(reason)<10 OR nullif(p_data->>'paper_batch','') IS NULL OR nullif(p_data->>'paper_number','') IS NULL THEN RAISE EXCEPTION 'V3_PAPER_REFERENCE_REQUIRED'; END IF;
  SELECT * INTO q FROM pulso_v3.questionnaires WHERE questionnaires.id=t.questionnaire_id;
  state:=p_data->>'outcome';id:=(p_data->>'response_id')::uuid;
  IF state='candidate' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(q.items) item WHERE item->>'id'=p_data->>'candidate_id') THEN RAISE EXCEPTION 'V3_CANDIDATE_VERSION_MISMATCH'; END IF;
  IF (p_data->>'time_precision') NOT IN('minutes','interval') THEN RAISE EXCEPTION 'V3_PAPER_TIME_PRECISION'; END IF;
  INSERT INTO pulso_v3.responses(id,assignment_id,person_id,point_id,district_id,questionnaire_id,candidate_id,outcome,consent,already_voted,started_at,captured_at,source,time_precision,paper_batch,paper_number,submitted_by,payload,payload_hash,disposition,reason_code)
   VALUES(id,t.id,t.person_id,point,d,q.id,nullif(p_data->>'candidate_id','')::uuid,state,(p_data->>'consent')::boolean,(p_data->>'already_voted')::boolean,
    (p_data->>'started_at')::timestamptz,(p_data->>'captured_at')::timestamptz,'paper',p_data->>'time_precision',p_data->>'paper_batch',p_data->>'paper_number',a.user_id,p_data,pulso_v3.hash(p_data),'pending_review','PAPER_REQUIRES_REVIEW');
  result:=jsonb_build_object('id',id,'disposition','pending_review');
 WHEN 'attachment.reserve' THEN
  IF p_data->>'purpose' NOT IN('site_authorization','methodology','incident') THEN RAISE EXCEPTION 'V3_INVALID_ATTACHMENT'; END IF;
  id:=gen_random_uuid();INSERT INTO pulso_v3.attachments(id,point_id,object_path,file_name,media_type,bytes,created_by,purpose)
   VALUES(id,point,'point/'||point::text||'/'||id::text,btrim(p_data->>'file_name'),p_data->>'media_type',(p_data->>'bytes')::bigint,a.user_id,p_data->>'purpose');
  result:=jsonb_build_object('id',id,'path','point/'||point::text||'/'||id::text);
 WHEN 'viewer.publish' THEN
  -- Deliberate, audited city snapshots; no live point/time slicing for viewers.
  SELECT public.v3_dashboard(d) INTO items;
  IF length(reason)<10 OR (p_data->>'release_authorized')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'V3_RELEASE_AUTHORIZATION_REQUIRED'; END IF;
  items:=items->'cities'->0;
  IF items IS NULL THEN RAISE EXCEPTION 'V3_BAD_DISTRICT'; END IF;
  n:=(items->>'candidate_base')::integer;
  IF n IS NULL OR n<o.viewer_min_base OR EXISTS(SELECT 1 FROM jsonb_array_elements(items->'candidates') x WHERE (x->>'count')::integer BETWEEN 1 AND 4) THEN
   items:=jsonb_build_object('district_id',d,'suppressed',true,'reason','MUESTRA_PEQUEÑA');
  ELSE items:=jsonb_build_object('district_id',d,'suppressed',false,'questionnaire_id',items->'questionnaire_id','candidate_base',items->'candidate_base','candidates',items->'candidates');END IF;
  INSERT INTO pulso_v3.viewer_snapshots(district_id,payload,published_at,published_by) VALUES(d,items,now_at,a.user_id)
   ON CONFLICT(district_id) DO UPDATE SET payload=excluded.payload,published_at=excluded.published_at,published_by=excluded.published_by;
 WHEN 'export.create' THEN
  -- Freeze a JSON dataset in one SQL statement, then page that same snapshot.
  state:=p_data->>'kind';id:=gen_random_uuid();d:=nullif(p_data->>'district_id','');
  IF state='responses' THEN
   SELECT count(*) INTO n FROM pulso_v3.responses WHERE d IS NULL OR district_id=d;
   IF n>100000 THEN RAISE EXCEPTION 'V3_EXPORT_FILTER_REQUIRED'; END IF;
   SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.received_at,x.id),'[]'::jsonb) INTO items FROM (
    SELECT r.id,r.receipt_id,r.district_id,r.assignment_id,r.person_id,r.point_id,r.questionnaire_id,r.candidate_id,r.outcome,r.source,r.time_precision,r.started_at,r.captured_at,r.received_at,r.disposition,r.reason_code
    FROM pulso_v3.responses r WHERE d IS NULL OR r.district_id=d) x;
  ELSIF state='summary' THEN SELECT public.v3_dashboard(d) INTO items;
  ELSIF state='audit' THEN
   IF (SELECT count(*) FROM pulso_v3.audit)>100000 THEN RAISE EXCEPTION 'V3_EXPORT_FILTER_REQUIRED';END IF;
   SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) INTO items FROM (SELECT * FROM pulso_v3.audit ORDER BY created_at DESC) x;
  ELSE RAISE EXCEPTION 'V3_INVALID_EXPORT'; END IF;
  INSERT INTO pulso_v3.export_snapshots(id,owner_id,kind,payload) VALUES(id,a.user_id,state,items);
  result:=jsonb_build_object('id',id,'kind',state,'rows',CASE WHEN jsonb_typeof(items)='array' THEN jsonb_array_length(items) ELSE 1 END,'snapshot_at',now_at);
 ELSE RAISE EXCEPTION 'V3_UNKNOWN_COMMAND';
 END CASE;
 PERFORM pulso_v3.log(a.user_id,p_action,id,p_request_id,jsonb_build_object('district_id',d,'point_id',point,'reason',reason));
 UPDATE pulso_v3.operations SET revision=revision+1,updated_at=now_at WHERE operations.id=1 AND p_action NOT IN('operation.save','operation.state','viewer.access');
 PERFORM pulso_v3.signal(d);
 INSERT INTO pulso_v3.command_receipts(actor_id,request_id,action,payload_hash,scope_district,scope_point,capability,result)
  VALUES(a.user_id,p_request_id,p_action,h,d,point,cap,result);
 RETURN result;
END $$;

CREATE FUNCTION public.v3_bootstrap(p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; o pulso_v3.operations; mode text; result jsonb;
BEGIN
 a:=pulso_v3.actor(); SELECT * INTO o FROM pulso_v3.operations WHERE id=1;
 SELECT operation_mode INTO mode FROM public.settings WHERE id=1;
 IF p_client IS NULL OR p_client<o.minimum_client THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED'; END IF;
 IF mode<>'v3' AND a.role<>'admin' THEN RAISE EXCEPTION 'V3_NOT_ACTIVATED'; END IF;
 WITH permitted_points AS (
  SELECT p.* FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id
  WHERE a.role='admin' OR pulso_v3.can(a.user_id,'operations',s.district_id,p.id)
    OR pulso_v3.can(a.user_id,'manage_points',s.district_id,p.id) OR pulso_v3.can(a.user_id,'assign',s.district_id,p.id)
    OR pulso_v3.can(a.user_id,'recruit',s.district_id,p.id) OR pulso_v3.can(a.user_id,'control_points',s.district_id,p.id)
    OR (a.role='interviewer' AND EXISTS(SELECT 1 FROM pulso_v3.assignments t WHERE t.point_id=p.id AND t.person_id=a.person_id AND t.status IN('pending','acknowledged','active','draining')))
 ), permitted_people AS (
  SELECT p.* FROM pulso_v3.people p WHERE a.role='admin' OR p.id=a.person_id
    OR pulso_v3.can(a.user_id,'recruit',p.home_district,p.recruit_point)
    OR EXISTS(SELECT 1 FROM pulso_v3.assignments t JOIN permitted_points pp ON pp.id=t.point_id WHERE t.person_id=p.id AND a.role='coordinator')
 ), permitted_tasks AS (
  SELECT t.* FROM pulso_v3.assignments t WHERE a.role='admin' OR t.person_id=a.person_id
   OR (a.role='coordinator' AND t.point_id IN(SELECT id FROM permitted_points))
 )
 SELECT jsonb_build_object(
  'actor',to_jsonb(a),'operation',CASE WHEN a.role='admin' THEN to_jsonb(o) ELSE jsonb_build_object('title',o.title,'contest',o.contest,'fieldwork_date',o.fieldwork_date,'phase',o.phase,'viewer_enabled',o.viewer_enabled,'minimum_client',o.minimum_client,'revision',o.revision,'lease_minutes',o.lease_minutes) END,
  'operation_mode',mode,'server_time',statement_timestamp(),'schema_version',8,
  'districts',(SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.sort_order),'[]') FROM public.districts d WHERE a.role='admin' OR public.v3_can_read_signal(d.id) OR pulso_v3.can(a.user_id,'view_results',d.id,NULL)),
  'grants',(SELECT coalesce(jsonb_agg(to_jsonb(g)),'[]') FROM pulso_v3.role_grants g WHERE (a.role='admin' OR g.user_id=a.user_id)),
  'points',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.code),'[]') FROM permitted_points p),
  'stations',(SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.code),'[]') FROM pulso_v3.stations s WHERE a.role='admin' OR s.id IN(SELECT station_id FROM permitted_points) OR pulso_v3.can(a.user_id,'manage_points',s.district_id,NULL)),
  'people',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.code),'[]') FROM permitted_people p),
  'assignments',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC),'[]') FROM permitted_tasks t),
  'actors',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.code),'[]') FROM pulso_v3.actors x WHERE a.role='admin' OR (a.role='coordinator' AND x.role='interviewer' AND x.person_id IN(SELECT id FROM permitted_people))),
  'questionnaires',(SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.district_id,q.version DESC),'[]') FROM pulso_v3.questionnaires q WHERE a.role='admin' OR
    (a.role='coordinator' AND q.state='published' AND EXISTS(SELECT 1 FROM permitted_points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE s.district_id=q.district_id)) OR q.id IN(SELECT questionnaire_id FROM permitted_tasks WHERE person_id=a.person_id)),
  'enrollments',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'person_id',e.person_id,'status',e.status,'expires_at',e.expires_at,'auth_user_id',e.auth_user_id,'revision',e.revision)),'[]') FROM pulso_v3.enrollments e WHERE a.role='admin' OR (a.role='coordinator' AND e.creator_id=a.user_id))
 ) INTO result;
 RETURN result;
END $$;
CREATE FUNCTION public.v3_training(p_answers jsonb,p_practice_ack boolean,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors; BEGIN
 IF p_client IS NULL OR p_client<(SELECT minimum_client FROM pulso_v3.operations WHERE id=1) THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED'; END IF;
 a:=pulso_v3.actor();IF a.role<>'interviewer' OR NOT a.enrolled THEN RAISE EXCEPTION 'V3_WORKER_ONLY' USING ERRCODE='42501';END IF;
 IF p_answers IS DISTINCT FROM '["after_voting","voluntary","pending_not_received"]'::jsonb OR p_practice_ack IS DISTINCT FROM true THEN RAISE EXCEPTION 'V3_TRAINING_RETRY';END IF;
 UPDATE pulso_v3.people SET training_passed_at=coalesce(training_passed_at,clock_timestamp()),training_version=1,training_practice_ack=true,revision=revision+1 WHERE id=a.person_id;
 PERFORM pulso_v3.log(a.user_id,'training.completed',a.person_id,NULL,jsonb_build_object('version',1));
 RETURN jsonb_build_object('training_passed',true,'approval_required',true);
END $$;
CREATE FUNCTION public.v3_ack_assignment(p_assignment uuid,p_version bigint,p_questionnaire uuid,p_point uuid,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;t pulso_v3.assignments;BEGIN
 IF p_client IS NULL OR p_client<(SELECT minimum_client FROM pulso_v3.operations WHERE id=1) THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED'; END IF;
 a:=pulso_v3.actor();SELECT * INTO t FROM pulso_v3.assignments WHERE id=p_assignment FOR UPDATE;
 IF a.role<>'interviewer' OR t.person_id IS DISTINCT FROM a.person_id THEN RAISE EXCEPTION 'V3_TASK_DENIED' USING ERRCODE='42501';END IF;
 IF p_questionnaire IS DISTINCT FROM t.questionnaire_id OR p_point IS DISTINCT FROM t.point_id THEN RAISE EXCEPTION 'V3_ASSIGNMENT_CHANGED';END IF;
 IF t.status='acknowledged' THEN RETURN to_jsonb(t);END IF;
 PERFORM pulso_v3.require_revision(t.revision,p_version);
 IF t.status<>'pending' THEN RAISE EXCEPTION 'V3_BAD_TRANSITION';END IF;
 UPDATE pulso_v3.assignments SET status='acknowledged',acknowledged_at=clock_timestamp(),revision=revision+1 WHERE id=p_assignment RETURNING * INTO t;
 PERFORM pulso_v3.log(a.user_id,'assignment.acknowledged',t.id,NULL,'{}');
 RETURN to_jsonb(t);
END $$;
CREATE FUNCTION public.v3_start_task(p_assignment uuid,p_device uuid,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;o pulso_v3.operations;w pulso_v3.people;t pulso_v3.assignments;old pulso_v3.assignments;
 p pulso_v3.points;q pulso_v3.questionnaires;g pulso_v3.capture_grants;sid uuid;now_at timestamptz:=clock_timestamp();stop_at timestamptz;
BEGIN
 SELECT * INTO o FROM pulso_v3.operations WHERE id=1 FOR SHARE;
 a:=pulso_v3.actor();sid:=(auth.jwt()->>'session_id')::uuid;
 IF a.role<>'interviewer' OR NOT a.enrolled OR p_device IS NULL THEN RAISE EXCEPTION 'V3_WORKER_ONLY' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM pulso_v3.people WHERE id=a.person_id FOR UPDATE;
 SELECT * INTO o FROM pulso_v3.operations WHERE id=1;
 IF (SELECT operation_mode FROM public.settings WHERE id=1)<>'v3' OR p_client IS NULL OR p_client<o.minimum_client THEN RAISE EXCEPTION 'V3_NOT_ACTIVATED';END IF;
 IF o.phase<>'running' OR o.fieldwork_date<>(now_at AT TIME ZONE 'America/Asuncion')::date OR w.approval<>'approved' OR NOT w.training_practice_ack THEN RAISE EXCEPTION 'V3_NOT_READY';END IF;
 SELECT * INTO t FROM pulso_v3.assignments WHERE id=p_assignment FOR UPDATE;
 IF t.person_id IS DISTINCT FROM a.person_id OR t.status NOT IN('acknowledged','active') THEN RAISE EXCEPTION 'V3_TASK_DENIED' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM pulso_v3.points WHERE id=t.point_id FOR SHARE;
 SELECT * INTO q FROM pulso_v3.questionnaires WHERE id=t.questionnaire_id;
 IF p.state<>'open' OR q.state<>'published' THEN RAISE EXCEPTION 'V3_POINT_OR_VERSION_CLOSED';END IF;
 SELECT * INTO old FROM pulso_v3.assignments WHERE person_id=a.person_id AND status='active' FOR UPDATE;
 IF old.id IS NOT NULL AND old.active_session_id IS DISTINCT FROM sid THEN RAISE EXCEPTION 'V3_DEVICE_IN_USE';END IF;
 IF t.status='active' AND t.active_session_id IS DISTINCT FROM sid THEN RAISE EXCEPTION 'V3_DEVICE_IN_USE';END IF;
 IF old.id IS NOT NULL AND old.id<>t.id THEN
  UPDATE pulso_v3.assignments SET status='draining',ended_at=now_at,drain_until=now_at+make_interval(hours=>o.drain_hours),revision=revision+1 WHERE id=old.id;
  PERFORM pulso_v3.log(a.user_id,'assignment.transferred',old.id,NULL,jsonb_build_object('next',t.id));
 END IF;
 UPDATE pulso_v3.assignments SET status='active',started_at=coalesce(started_at,now_at),active_session_id=sid,revision=revision+1 WHERE id=t.id RETURNING * INTO t;
 SELECT * INTO g FROM pulso_v3.capture_grants WHERE assignment_id=t.id AND auth_session_id=sid AND revoked_at IS NULL AND capture_until>now_at+interval '5 minutes' ORDER BY issued_at DESC LIMIT 1;
 IF g.id IS NOT NULL AND g.device_id<>p_device THEN RAISE EXCEPTION 'V3_DEVICE_IN_USE';END IF;
 IF g.id IS NULL THEN
  stop_at:=least(now_at+make_interval(mins=>o.lease_minutes),(o.fieldwork_date+1)::timestamp AT TIME ZONE 'America/Asuncion');
  INSERT INTO pulso_v3.capture_grants(assignment_id,user_id,auth_session_id,device_id,capture_until,upload_until)
   VALUES(t.id,a.user_id,sid,p_device,stop_at,stop_at+make_interval(hours=>o.drain_hours)) RETURNING * INTO g;
 END IF;
 PERFORM pulso_v3.log(a.user_id,'task.lease',t.id,NULL,jsonb_build_object('grant_id',g.id));
 RETURN jsonb_build_object('assignment',to_jsonb(t),'grant',to_jsonb(g),'questionnaire',to_jsonb(q),'point',to_jsonb(p),
  'station',(SELECT to_jsonb(s) FROM pulso_v3.stations s WHERE id=p.station_id),'server_time',now_at,'minimum_client',o.minimum_client);
END $$;
CREATE FUNCTION public.v3_submit_response(p_event jsonb,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;o pulso_v3.operations;w pulso_v3.people;t pulso_v3.assignments;g pulso_v3.capture_grants;
 p pulso_v3.points;s pulso_v3.stations;q pulso_v3.questionnaires;r pulso_v3.responses;
 rid uuid;h text;start_at timestamptz;capture_at timestamptz;now_at timestamptz:=clock_timestamp();cid uuid;outcome text;disp text:='accepted';why text:='';geo jsonb;lat double precision;lon double precision;recovered boolean:=false;
BEGIN
 SELECT * INTO o FROM pulso_v3.operations WHERE id=1 FOR SHARE; a:=pulso_v3.actor();
 IF a.role<>'interviewer' OR NOT a.enrolled OR (SELECT operation_mode FROM public.settings WHERE id=1)<>'v3' THEN RAISE EXCEPTION 'V3_WORKER_ONLY' USING ERRCODE='42501';END IF;
 IF p_client IS NULL OR p_client<o.minimum_client THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED';END IF;
 IF jsonb_typeof(p_event) IS DISTINCT FROM 'object' OR octet_length(p_event::text)>16000 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_event) k WHERE k NOT IN('id','assignment_id','grant_id','questionnaire_id','point_id','started_at','captured_at','candidate_id','outcome','consent','already_voted','geo')) THEN RAISE EXCEPTION 'V3_INVALID_EVENT';END IF;
 rid:=(p_event->>'id')::uuid;IF rid IS NULL THEN RAISE EXCEPTION 'V3_EVENT_ID_REQUIRED';END IF;
 h:=pulso_v3.hash(p_event);PERFORM pg_advisory_xact_lock(hashtextextended(rid::text,4));
 SELECT * INTO r FROM pulso_v3.responses WHERE id=rid;
 IF FOUND THEN
  IF r.submitted_by<>a.user_id OR r.person_id<>a.person_id THEN RAISE EXCEPTION 'V3_RECEIPT_DENIED' USING ERRCODE='42501';END IF;
  IF r.payload_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT' USING ERRCODE='23514';END IF;
  RETURN jsonb_build_object('response_id',r.id,'receipt_id',r.receipt_id,'received_at',r.received_at,'disposition',r.disposition,'reason_code',r.reason_code,'duplicate',true,'payload_hash',r.payload_hash);
 END IF;
 SELECT * INTO t FROM pulso_v3.assignments WHERE id=(p_event->>'assignment_id')::uuid FOR SHARE;
 SELECT * INTO g FROM pulso_v3.capture_grants WHERE id=(p_event->>'grant_id')::uuid FOR SHARE;
 SELECT * INTO w FROM pulso_v3.people WHERE id=a.person_id;
 IF t.person_id IS DISTINCT FROM a.person_id OR g.assignment_id IS DISTINCT FROM t.id OR g.user_id IS DISTINCT FROM a.user_id
   THEN RAISE EXCEPTION 'V3_TASK_DENIED' USING ERRCODE='42501';END IF;
 recovered:=g.auth_session_id IS DISTINCT FROM (auth.jwt()->>'session_id')::uuid;
 IF recovered AND NOT EXISTS(SELECT 1 FROM pulso_v3.upload_recoveries ur WHERE ur.grant_id=g.id AND ur.user_id=a.user_id AND ur.auth_session_id=(auth.jwt()->>'session_id')::uuid) THEN RAISE EXCEPTION 'V3_UPLOAD_RECOVERY_REQUIRED' USING ERRCODE='42501';END IF;
 IF w.approval<>'approved' THEN RAISE EXCEPTION 'V3_WORKER_NOT_APPROVED' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM pulso_v3.points WHERE id=t.point_id;SELECT * INTO s FROM pulso_v3.stations WHERE id=p.station_id;
 SELECT * INTO q FROM pulso_v3.questionnaires WHERE id=t.questionnaire_id;
 IF t.point_id IS DISTINCT FROM (p_event->>'point_id')::uuid OR q.id IS DISTINCT FROM (p_event->>'questionnaire_id')::uuid OR q.district_id<>s.district_id THEN RAISE EXCEPTION 'V3_ASSIGNMENT_CHANGED' USING ERRCODE='23514';END IF;
 cid:=nullif(p_event->>'candidate_id','')::uuid;outcome:=p_event->>'outcome';
 IF outcome IS NULL OR outcome NOT IN('candidate','blank','invalid','undisclosed','refused') OR (outcome='candidate')<>(cid IS NOT NULL) THEN RAISE EXCEPTION 'V3_INVALID_ANSWER';END IF;
 IF cid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(q.items) item WHERE item->>'id'=cid::text) THEN RAISE EXCEPTION 'V3_CANDIDATE_VERSION_MISMATCH' USING ERRCODE='23514';END IF;
 IF jsonb_typeof(p_event->'already_voted') IS DISTINCT FROM 'boolean' OR p_event->'already_voted'<>'true'::jsonb OR jsonb_typeof(p_event->'consent') IS DISTINCT FROM 'boolean'
  OR (outcome='refused' AND p_event->'consent'<>'false'::jsonb) OR (outcome<>'refused' AND p_event->'consent'<>'true'::jsonb) THEN RAISE EXCEPTION 'V3_CONSENT_REQUIRED';END IF;
 start_at:=(p_event->>'started_at')::timestamptz;capture_at:=(p_event->>'captured_at')::timestamptz;
 IF start_at IS NULL OR capture_at IS NULL OR start_at>capture_at OR start_at<capture_at-interval '2 hours' OR NOT isfinite(start_at) OR NOT isfinite(capture_at) THEN RAISE EXCEPTION 'V3_INVALID_TIME';END IF;
 geo:=coalesce(p_event->'geo','{"status":"not_requested"}'::jsonb);
 IF jsonb_typeof(geo) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(geo) k WHERE k NOT IN('status','latitude','longitude','accuracy_m','captured_at')) OR geo->>'status' IS NULL OR geo->>'status' NOT IN('not_requested','granted','denied','unavailable','stale') THEN RAISE EXCEPTION 'V3_INVALID_GPS';END IF;
 IF geo->>'status'='granted' THEN
  lat:=(geo->>'latitude')::double precision;lon:=(geo->>'longitude')::double precision;
  IF lat IS NULL OR lon IS NULL OR NOT(lat BETWEEN -90 AND 90) OR NOT(lon BETWEEN -180 AND 180)
    OR (geo->>'accuracy_m') IS NULL OR NOT((geo->>'accuracy_m')::double precision BETWEEN 0 AND 100000)
    OR (geo->>'captured_at') IS NULL OR NOT isfinite((geo->>'captured_at')::timestamptz) OR (geo->>'captured_at')::timestamptz>capture_at+interval '30 seconds' OR (geo->>'captured_at')::timestamptz<capture_at-interval '15 minutes' THEN RAISE EXCEPTION 'V3_INVALID_GPS';END IF;
 ELSE IF geo ?| ARRAY['latitude','longitude','accuracy_m','captured_at'] THEN RAISE EXCEPTION 'V3_GPS_WITHOUT_PERMISSION';END IF;END IF;
 -- Device-declared times are not independent proof. Uncertain cases are preserved, not silently counted.
 IF g.revoked_at IS NOT NULL THEN why:='GRANT_REVOKED';
 ELSIF recovered THEN why:='SESSION_RECOVERED';
 ELSIF o.phase='paused' THEN why:='GLOBAL_PAUSED';
 ELSIF o.phase='setup' THEN why:='NOT_RUNNING';
 ELSIF t.status NOT IN('active','draining') THEN why:='TASK_ENDED';
 ELSIF capture_at>now_at+interval '2 minutes' OR start_at<g.issued_at-interval '30 seconds' OR (capture_at AT TIME ZONE 'America/Asuncion')::date<>o.fieldwork_date THEN why:='CLOCK_UNCERTAIN';
 ELSIF capture_at>g.capture_until OR (t.ended_at IS NOT NULL AND capture_at>t.ended_at) THEN why:='CAPTURE_OUTSIDE_WINDOW';
 ELSIF now_at>g.upload_until OR (t.drain_until IS NOT NULL AND now_at>t.drain_until) THEN why:='UPLOAD_LATE';
 ELSIF q.state<>'published' THEN why:='QUESTIONNAIRE_SUPERSEDED';
 ELSIF NOT EXISTS(SELECT 1 FROM pulso_v3.point_windows pw WHERE pw.point_id=p.id AND capture_at>=pw.opened_at AND (pw.closed_at IS NULL OR capture_at<=pw.closed_at)) THEN why:='POINT_WINDOW_UNCERTAIN';
 END IF;
 IF why<>'' THEN disp:='pending_review';END IF;
 INSERT INTO pulso_v3.responses(id,assignment_id,person_id,point_id,district_id,questionnaire_id,grant_id,candidate_id,outcome,consent,already_voted,started_at,captured_at,source,submitted_by,payload,payload_hash,disposition,reason_code)
 VALUES(rid,t.id,a.person_id,p.id,s.district_id,q.id,g.id,cid,outcome,(p_event->>'consent')::boolean,true,start_at,capture_at,'digital',a.user_id,p_event,h,disp,why) RETURNING * INTO r;
 PERFORM pulso_v3.log(a.user_id,'capture.received',rid,NULL,jsonb_build_object('disposition',disp,'district_id',s.district_id));
 PERFORM pulso_v3.signal(s.district_id);
 RETURN jsonb_build_object('response_id',r.id,'receipt_id',r.receipt_id,'received_at',r.received_at,'disposition',r.disposition,'reason_code',r.reason_code,'duplicate',false,'payload_hash',r.payload_hash);
END $$;
CREATE FUNCTION public.v3_receipts(p_ids uuid[]) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;BEGIN
 a:=pulso_v3.actor();IF cardinality(p_ids)>500 THEN RAISE EXCEPTION 'V3_BATCH_TOO_LARGE';END IF;
 RETURN(SELECT coalesce(jsonb_agg(jsonb_build_object('response_id',r.id,'receipt_id',r.receipt_id,'received_at',r.received_at,'disposition',r.disposition,'reason_code',r.reason_code,'payload_hash',r.payload_hash)),'[]')
  FROM pulso_v3.responses r WHERE r.id=ANY(p_ids) AND (r.person_id=a.person_id OR a.role='admin'));
END $$;
CREATE FUNCTION public.v3_records(p_district text DEFAULT NULL,p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;BEGIN
 a:=pulso_v3.actor();IF a.role NOT IN('admin','interviewer') THEN RAISE EXCEPTION 'V3_RECORDS_DENIED' USING ERRCODE='42501';END IF;
 IF p_limit NOT BETWEEN 1 AND 500 OR p_limit IS NULL OR (p_before IS NULL)<>(p_before_id IS NULL) THEN RAISE EXCEPTION 'V3_INVALID_PAGE';END IF;
 RETURN(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.received_at DESC,x.id DESC),'[]') FROM (
  SELECT r.* FROM pulso_v3.responses r WHERE (a.role='admin' OR r.person_id=a.person_id) AND (p_district IS NULL OR r.district_id=p_district)
  AND (p_before IS NULL OR (r.received_at,r.id)<(p_before,p_before_id)) ORDER BY r.received_at DESC,r.id DESC LIMIT p_limit) x);
END $$;
CREATE FUNCTION public.v3_void_own(p_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;r pulso_v3.responses;BEGIN
 a:=pulso_v3.actor();SELECT * INTO r FROM pulso_v3.responses WHERE id=p_id FOR UPDATE;
 IF a.role<>'interviewer' OR r.person_id IS DISTINCT FROM a.person_id OR r.submitted_by<>a.user_id OR r.received_at<clock_timestamp()-interval '10 minutes' THEN RAISE EXCEPTION 'V3_VOID_DENIED' USING ERRCODE='42501';END IF;
 IF p_reason IS DISTINCT FROM 'capture_error' THEN RAISE EXCEPTION 'V3_VOID_REASON_REQUIRED';END IF;
 IF r.disposition='excluded' THEN RETURN jsonb_build_object('id',r.id,'disposition','excluded');END IF;
 UPDATE pulso_v3.responses SET disposition='excluded',reason_code='CAPTURE_ERROR',revision=revision+1 WHERE id=p_id;
 PERFORM pulso_v3.log(a.user_id,'capture.voided',p_id,NULL,jsonb_build_object('reason','capture_error'));
 DELETE FROM pulso_v3.viewer_snapshots WHERE district_id=r.district_id;PERFORM pulso_v3.signal(r.district_id);
 RETURN jsonb_build_object('id',r.id,'disposition','excluded');
END $$;
CREATE FUNCTION public.v3_dashboard(p_district text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;o pulso_v3.operations;result jsonb;BEGIN
 a:=pulso_v3.actor();SELECT * INTO o FROM pulso_v3.operations WHERE id=1;
 IF a.role='viewer' THEN
  IF NOT o.viewer_enabled THEN RAISE EXCEPTION 'V3_VIEWER_RESULTS_PENDING' USING ERRCODE='42501';END IF;
  IF p_district IS NOT NULL AND NOT pulso_v3.can(a.user_id,'view_results',p_district,NULL) THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501';END IF;
  RETURN jsonb_build_object('server_time',statement_timestamp(),'read_only',true,'cities',
   (SELECT coalesce(jsonb_agg(v.payload||jsonb_build_object('published_at',v.published_at) ORDER BY v.district_id),'[]') FROM pulso_v3.viewer_snapshots v
    WHERE pulso_v3.can(a.user_id,'view_results',v.district_id,NULL) AND (p_district IS NULL OR v.district_id=p_district)));
 END IF;
 IF a.role NOT IN('admin','coordinator') THEN RAISE EXCEPTION 'V3_DASHBOARD_DENIED' USING ERRCODE='42501';END IF;
 WITH pts AS (
  SELECT p.*,s.district_id,s.name station_name,s.address FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id
  WHERE (a.role='admin' OR pulso_v3.can(a.user_id,'operations',s.district_id,p.id)) AND (p_district IS NULL OR s.district_id=p_district)
 ), rs AS (SELECT r.* FROM pulso_v3.responses r JOIN pts ON pts.id=r.point_id),
 ds AS (SELECT d.* FROM public.districts d WHERE (p_district IS NULL OR d.id=p_district) AND (a.role='admin' OR EXISTS(SELECT 1 FROM pts WHERE district_id=d.id))),
 city_rows AS (
 SELECT d.id AS district_id,d.name,d.code,q.id questionnaire_id,q.version questionnaire_version,
  (SELECT count(*) FROM pts p WHERE p.district_id=d.id) AS configured_points,
  (SELECT count(*) FROM pts p WHERE p.district_id=d.id AND EXISTS(SELECT 1 FROM pulso_v3.point_windows w WHERE w.point_id=p.id)) AS started_points,
  (SELECT count(*) FROM rs r WHERE r.district_id=d.id) AS received,
  (SELECT count(*) FROM rs r WHERE r.district_id=d.id AND r.disposition='pending_review') AS pending_review,
  (SELECT count(*) FROM rs r WHERE r.district_id=d.id AND r.disposition='excluded') AS excluded,
  (SELECT count(*) FROM rs r WHERE r.district_id=d.id AND r.disposition='accepted') AS accepted_all_versions,
  CASE WHEN a.role='admin' THEN (SELECT count(*) FROM rs r WHERE r.district_id=d.id AND r.questionnaire_id=q.id AND r.disposition='accepted' AND r.outcome='candidate') END AS candidate_base,
  CASE WHEN a.role='admin' THEN (SELECT jsonb_agg(item||jsonb_build_object('count',(SELECT count(*) FROM rs r WHERE r.questionnaire_id=q.id AND r.disposition='accepted' AND r.candidate_id=(item->>'id')::uuid))) FROM jsonb_array_elements(q.items) item) END AS candidates,
  CASE WHEN a.role='admin' THEN (SELECT coalesce(jsonb_object_agg(x.outcome,x.n),'{}') FROM (SELECT outcome,count(*) n FROM rs r WHERE r.questionnaire_id=q.id AND r.disposition='accepted' AND r.outcome<>'candidate' GROUP BY outcome) x) END AS other_answers,
  (SELECT max(received_at) FROM rs r WHERE r.district_id=d.id) AS last_received
 FROM ds d LEFT JOIN pulso_v3.questionnaires q ON q.district_id=d.id AND q.state='published'
 )
 SELECT jsonb_build_object('server_time',statement_timestamp(),'scope','configured_points_only','cities',
  (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.district_id),'[]') FROM city_rows c),
  'points',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'label',p.label,'station_name',p.station_name,'district_id',p.district_id,'state',p.state,'planned',p.planned,
    'received',(SELECT count(*) FROM rs r WHERE r.point_id=p.id),'last_received',(SELECT max(received_at) FROM rs r WHERE r.point_id=p.id),
    'active_workers',(SELECT count(*) FROM pulso_v3.assignments t WHERE t.point_id=p.id AND t.status='active'),
    'has_started',EXISTS(SELECT 1 FROM pulso_v3.point_windows w WHERE w.point_id=p.id)) ORDER BY p.code),'[]') FROM pts p),
  'team',(SELECT coalesce(jsonb_agg(jsonb_build_object('person_id',w.id,'code',w.code,'name',w.display_name,'assignment_id',t.id,'status',t.status,'point_id',t.point_id,
    'last_seen',(SELECT max(cg.last_seen) FROM pulso_v3.capture_grants cg WHERE cg.assignment_id=t.id),
    'pending_reported',(SELECT cg.pending_reported FROM pulso_v3.capture_grants cg WHERE cg.assignment_id=t.id AND cg.pending_reported_at IS NOT NULL ORDER BY cg.pending_reported_at DESC LIMIT 1),
    'pending_reported_at',(SELECT max(cg.pending_reported_at) FROM pulso_v3.capture_grants cg WHERE cg.assignment_id=t.id),
    'last_received',(SELECT max(received_at) FROM rs r WHERE r.assignment_id=t.id),'received',(SELECT count(*) FROM rs r WHERE r.assignment_id=t.id))),'[]')
    FROM pulso_v3.assignments t JOIN pulso_v3.people w ON w.id=t.person_id JOIN pts p ON p.id=t.point_id WHERE t.status IN('pending','acknowledged','active','draining'))
 ) INTO result;
 RETURN result;
END $$;
CREATE FUNCTION public.v3_export_page(p_id uuid,p_offset integer DEFAULT 0,p_limit integer DEFAULT 250) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;e pulso_v3.export_snapshots;BEGIN
 a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 SELECT * INTO e FROM pulso_v3.export_snapshots WHERE id=p_id AND owner_id=a.user_id AND expires_at>statement_timestamp();
 IF e.id IS NULL OR p_offset<0 OR p_limit NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'V3_INVALID_EXPORT';END IF;
 IF jsonb_typeof(e.payload)<>'array' THEN RETURN jsonb_build_object('snapshot_at',e.created_at,'data',e.payload,'next_offset',NULL);END IF;
 RETURN jsonb_build_object('snapshot_at',e.created_at,'data',(SELECT coalesce(jsonb_agg(x.value ORDER BY x.ordinality),'[]') FROM jsonb_array_elements(e.payload) WITH ORDINALITY x WHERE x.ordinality>p_offset AND x.ordinality<=p_offset+p_limit),
  'next_offset',CASE WHEN p_offset+p_limit<jsonb_array_length(e.payload) THEN p_offset+p_limit END,'total',jsonb_array_length(e.payload));
END $$;
-- Import only raw data, never formulas; validated preview is stored and applied with revision check.
CREATE FUNCTION public.v3_import_preview(p_kind text,p_rows jsonb,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;o pulso_v3.operations;row jsonb;issues jsonb:='[]';i integer:=0;id uuid;codes text[]:='{}';input_code text;
BEGIN
 a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 SELECT * INTO o FROM pulso_v3.operations WHERE operations.id=1;
 IF p_client IS NULL OR p_client<o.minimum_client THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED';END IF;
 IF p_kind NOT IN('stations','points','people','questionnaires','assignments') OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 1000 OR octet_length(p_rows::text)>1000000 THEN RAISE EXCEPTION 'V3_IMPORT_LIMIT';END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  i:=i+1;input_code:=upper(btrim(coalesce(row->>'code','')));
  IF jsonb_typeof(row)<>'object' OR row?'__proto__' OR EXISTS(SELECT 1 FROM jsonb_each_text(row) x WHERE x.key~*'(password|secret|token|voter|cedula)' OR x.value~'^[=+@]') THEN issues:=issues||jsonb_build_object('row',i,'error','UNSAFE_CONTENT');END IF;
  IF p_kind='stations' THEN
   IF input_code='' OR input_code=ANY(codes) OR NOT EXISTS(SELECT 1 FROM public.districts WHERE districts.id=row->>'district_id') OR char_length(btrim(coalesce(row->>'name','')))=0 OR char_length(btrim(coalesce(row->>'address','')))<5 OR EXISTS(SELECT 1 FROM pulso_v3.stations s WHERE s.code=input_code) THEN issues:=issues||jsonb_build_object('row',i,'error','INVALID_OR_EXISTING_STATION');END IF;
  ELSIF p_kind='points' THEN
   IF input_code='' OR input_code=ANY(codes) OR char_length(btrim(coalesce(row->>'label','')))<2 OR NOT EXISTS(SELECT 1 FROM pulso_v3.stations s WHERE s.code=upper(btrim(row->>'station_code'))) OR EXISTS(SELECT 1 FROM pulso_v3.points p WHERE p.code=input_code) THEN issues:=issues||jsonb_build_object('row',i,'error','INVALID_OR_EXISTING_POINT');END IF;
  ELSIF p_kind='people' THEN
   IF char_length(btrim(coalesce(row->>'display_name',''))) NOT BETWEEN 1 AND 100 OR NOT EXISTS(SELECT 1 FROM public.districts WHERE districts.id=row->>'district_id') THEN issues:=issues||jsonb_build_object('row',i,'error','INVALID_PERSON');END IF;
  END IF;
  IF p_kind='questionnaires' THEN
   BEGIN
    PERFORM pulso_v3.validate_items(row->'items');
    IF NOT EXISTS(SELECT 1 FROM public.districts WHERE districts.id=row->>'district_id') OR char_length(coalesce(row->>'contest','')) NOT BETWEEN 1 AND 120
       OR (row->>'sample_interval')::integer NOT BETWEEN 1 AND 100 OR char_length(coalesce(row->>'methodology',''))>4000 THEN RAISE EXCEPTION 'invalid';END IF;
   EXCEPTION WHEN OTHERS THEN issues:=issues||jsonb_build_object('row',i,'error','INVALID_QUESTIONNAIRE');END;
  ELSIF p_kind='assignments' THEN
   IF NOT EXISTS(SELECT 1 FROM pulso_v3.people w WHERE w.code=row->>'person_code') OR NOT EXISTS(SELECT 1 FROM pulso_v3.points p WHERE p.code=row->>'point_code' AND p.state IN('approved','open','paused')) OR char_length(coalesce(row->>'reason',''))<5 THEN issues:=issues||jsonb_build_object('row',i,'error','INVALID_ASSIGNMENT');END IF;
  END IF;
  codes:=array_append(codes,input_code);
 END LOOP;
 IF jsonb_array_length(issues)>0 THEN RETURN jsonb_build_object('valid',false,'errors',issues);END IF;
 id:=gen_random_uuid();INSERT INTO pulso_v3.import_batches(id,owner_id,format_version,kind,payload,batch_hash,base_revision)
  VALUES(id,a.user_id,'PULSO_R3',p_kind,p_rows,pulso_v3.hash(p_rows),o.revision);
 RETURN jsonb_build_object('valid',true,'batch_id',id,'rows',jsonb_array_length(p_rows),'base_revision',o.revision,'hash',pulso_v3.hash(p_rows),'preview',p_rows);
END $$;
CREATE FUNCTION public.v3_import_apply(p_batch uuid,p_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;b pulso_v3.import_batches;o pulso_v3.operations;row jsonb;id uuid;person_id uuid;point_id uuid;
BEGIN
 a:=pulso_v3.actor();IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 SELECT * INTO o FROM pulso_v3.operations WHERE operations.id=1 FOR UPDATE;
 SELECT * INTO b FROM pulso_v3.import_batches WHERE import_batches.id=p_batch AND owner_id=a.user_id FOR UPDATE;
 IF b.id IS NULL OR b.batch_hash IS DISTINCT FROM p_hash THEN RAISE EXCEPTION 'V3_INVALID_BATCH';END IF;
 IF b.state='applied' THEN RETURN jsonb_build_object('id',b.id,'duplicate',true);END IF;
 PERFORM pulso_v3.require_revision(o.revision,b.base_revision);
 FOR row IN SELECT value FROM jsonb_array_elements(b.payload) LOOP
  IF b.kind='stations' THEN INSERT INTO pulso_v3.stations(district_id,code,name,address,official_code)
   VALUES(row->>'district_id',upper(btrim(row->>'code')),btrim(row->>'name'),btrim(row->>'address'),btrim(coalesce(row->>'official_code','')));
  ELSIF b.kind='points' THEN SELECT s.id INTO id FROM pulso_v3.stations s WHERE s.code=upper(btrim(row->>'station_code'));
   INSERT INTO pulso_v3.points(station_id,code,label,planned) VALUES(id,upper(btrim(row->>'code')),btrim(row->>'label'),coalesce((row->>'planned')::boolean,true));
  ELSIF b.kind='people' THEN INSERT INTO pulso_v3.people(display_name,home_district,created_by) VALUES(btrim(row->>'display_name'),row->>'district_id',a.user_id);
  ELSIF b.kind='questionnaires' THEN PERFORM public.v3_command('questionnaire.save',row,gen_random_uuid(),0);
  ELSIF b.kind='assignments' THEN
   SELECT w.id INTO person_id FROM pulso_v3.people w WHERE w.code=row->>'person_code';SELECT p.id INTO point_id FROM pulso_v3.points p WHERE p.code=row->>'point_code';
   PERFORM public.v3_command('assignment.create',jsonb_build_object('person_id',person_id,'point_id',point_id,'reason',row->>'reason'),gen_random_uuid(),0);
  END IF;
 END LOOP;
 UPDATE pulso_v3.import_batches SET state='applied',applied_at=clock_timestamp() WHERE import_batches.id=p_batch;
 UPDATE pulso_v3.operations SET revision=revision+1 WHERE operations.id=1;
 PERFORM pulso_v3.log(a.user_id,'import.applied',p_batch,NULL,jsonb_build_object('kind',b.kind,'hash',b.batch_hash,'rows',jsonb_array_length(b.payload)));
 PERFORM pulso_v3.signal(NULL);
 RETURN jsonb_build_object('id',b.id,'rows',jsonb_array_length(b.payload),'drafts_only',true);
END $$;
DO $$ DECLARE f record;BEGIN
 FOR f IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('public','pulso_v3') AND (n.nspname='pulso_v3' OR p.proname LIKE 'v3_%') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.sig);
  IF f.sig::text LIKE 'v3_%' OR f.sig::text LIKE 'public.v3_%' THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f.sig);END IF;
 END LOOP;
END $$;
INSERT INTO pulso_v3.schema_versions(version) VALUES(5);

-- 006_v3_enrollment.sql
-- Pulso V3 / 006: service-only account saga and one-claimant enrollment.

CREATE TABLE pulso_v3.revoked_sessions (
 session_id uuid PRIMARY KEY,user_id uuid NOT NULL,reason text NOT NULL,revoked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE pulso_v3.access_requests (
 actor_id uuid NOT NULL,request_id uuid NOT NULL,code text NOT NULL,display_name text NOT NULL,
 role text NOT NULL CHECK(role IN('admin','coordinator','viewer')),auth_user_id uuid,
 state text NOT NULL DEFAULT 'preparing' CHECK(state IN('preparing','auth_created','completed')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(actor_id,request_id),UNIQUE(code)
);
ALTER TABLE pulso_v3.revoked_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pulso_v3.access_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pulso_v3.revoked_sessions,pulso_v3.access_requests FROM PUBLIC,anon,authenticated;
GRANT ALL ON pulso_v3.revoked_sessions,pulso_v3.access_requests TO service_role;
CREATE OR REPLACE FUNCTION pulso_v3.actor() RETURNS pulso_v3.actors
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;sid uuid;BEGIN
 sid:=nullif(auth.jwt()->>'session_id','')::uuid;
 IF auth.uid() IS NULL OR sid IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=sid AND user_id=auth.uid())
  OR EXISTS(SELECT 1 FROM pulso_v3.revoked_sessions WHERE session_id=sid) THEN RAISE EXCEPTION 'V3_SESSION_REQUIRED' USING ERRCODE='42501';END IF;
 SELECT * INTO a FROM pulso_v3.actors WHERE user_id=auth.uid() AND active;
 IF a.user_id IS NULL THEN RAISE EXCEPTION 'V3_ACCOUNT_DISABLED' USING ERRCODE='42501';END IF;
 RETURN a;
END $$;
CREATE FUNCTION pulso_v3.assert_service_actor(u uuid,sid uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN
 IF sid IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=sid AND user_id=u)
 OR EXISTS(SELECT 1 FROM pulso_v3.revoked_sessions WHERE session_id=sid)
 OR NOT EXISTS(SELECT 1 FROM pulso_v3.actors WHERE user_id=u AND active) THEN
  RAISE EXCEPTION 'V3_SESSION_REQUIRED' USING ERRCODE='42501';END IF;
END $$;
CREATE FUNCTION public.v3_request_budget(p_kind text,p_bucket text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE cap integer;n integer;BEGIN
 cap:=CASE p_kind WHEN 'join_ip' THEN 150 WHEN 'join_token' THEN 15 WHEN 'admin' THEN 60 END;
 IF cap IS NULL OR length(p_bucket)<>64 THEN RAISE EXCEPTION 'V3_INVALID_BUDGET';END IF;
 INSERT INTO pulso_v3.rate_limits(bucket,window_start,attempts) VALUES(p_kind||':'||p_bucket,clock_timestamp(),1)
 ON CONFLICT(bucket) DO UPDATE SET attempts=CASE WHEN rate_limits.window_start<clock_timestamp()-interval '1 minute' THEN 1 ELSE rate_limits.attempts+1 END,
 window_start=CASE WHEN rate_limits.window_start<clock_timestamp()-interval '1 minute' THEN clock_timestamp() ELSE rate_limits.window_start END RETURNING attempts INTO n;
 RETURN n<=cap;
END $$;
REVOKE ALL ON FUNCTION public.v3_request_budget(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_request_budget(text,text) TO service_role;
CREATE FUNCTION pulso_v3.rate_limit(p_bucket text,p_max integer,p_seconds integer DEFAULT 60) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n integer;BEGIN
 INSERT INTO pulso_v3.rate_limits(bucket,window_start,attempts) VALUES(p_bucket,clock_timestamp(),1)
 ON CONFLICT(bucket) DO UPDATE SET
 attempts=CASE WHEN rate_limits.window_start<clock_timestamp()-make_interval(secs=>p_seconds) THEN 1 ELSE rate_limits.attempts+1 END,
 window_start=CASE WHEN rate_limits.window_start<clock_timestamp()-make_interval(secs=>p_seconds) THEN clock_timestamp() ELSE rate_limits.window_start END
 RETURNING attempts INTO n;
 IF n>p_max THEN RAISE EXCEPTION 'V3_RATE_LIMIT';END IF;
END $$;
CREATE FUNCTION public.v3_enrollment_service(p_step text,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
DECLARE e pulso_v3.enrollments;w pulso_v3.people;a pulso_v3.actors;pr pulso_v3.provision_requests;
 id uuid;u uuid;pt uuid;req uuid;claim text;lockid uuid;mail text;sid uuid;
BEGIN
 IF jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>8000 THEN RAISE EXCEPTION 'V3_INVALID_REQUEST';END IF;
 IF p_step='issue' THEN
  u:=(p_data->>'actor_id')::uuid;PERFORM pulso_v3.assert_service_actor(u,(p_data->>'session_id')::uuid);req:=(p_data->>'request_id')::uuid;pt:=nullif(p_data->>'point_id','')::uuid;
  SELECT * INTO w FROM pulso_v3.people WHERE people.id=(p_data->>'person_id')::uuid FOR UPDATE;
  IF w.id IS NULL OR w.approval IN('retired','suspended') THEN RAISE EXCEPTION 'V3_PERSON_UNAVAILABLE';END IF;
  IF w.recruit_point IS DISTINCT FROM pt THEN RAISE EXCEPTION 'V3_INVITE_SCOPE_MISMATCH';END IF;
  PERFORM pulso_v3.require_cap(u,'recruit',w.home_district,w.recruit_point);
  PERFORM pulso_v3.rate_limit('issuer:'||u::text,40);
  SELECT * INTO e FROM pulso_v3.enrollments WHERE creator_id=u AND request_id=req;
  IF e.id IS NOT NULL THEN RETURN jsonb_build_object('id',e.id,'status',e.status,'reissue_required',true);END IF;
  IF EXISTS(SELECT 1 FROM pulso_v3.actors WHERE person_id=w.id AND enrolled AND active) THEN RAISE EXCEPTION 'V3_ALREADY_ENROLLED';END IF;
  UPDATE pulso_v3.enrollments SET status='revoked',revision=revision+1 WHERE person_id=w.id AND status IN('issued','claimed','auth_created','ready');
  id:=gen_random_uuid();INSERT INTO pulso_v3.enrollments(id,person_id,creator_id,point_id,token_hash,expires_at,request_id)
   VALUES(id,w.id,u,pt,p_data->>'token_hash',clock_timestamp()+interval '10 minutes',req) RETURNING * INTO e;
  INSERT INTO pulso_v3.provision_requests(enrollment_id) VALUES(id);
  PERFORM pulso_v3.log(u,'enrollment.issued',id,req,jsonb_build_object('person_id',w.id,'district_id',w.home_district));
  RETURN jsonb_build_object('id',id,'expires_at',e.expires_at,'person_code',w.code,'name',w.display_name);
 ELSIF p_step='revoke' THEN
  u:=(p_data->>'actor_id')::uuid;PERFORM pulso_v3.assert_service_actor(u,(p_data->>'session_id')::uuid);SELECT * INTO e FROM pulso_v3.enrollments WHERE enrollments.id=(p_data->>'id')::uuid FOR UPDATE;
  SELECT * INTO w FROM pulso_v3.people WHERE people.id=e.person_id;PERFORM pulso_v3.require_cap(u,'recruit',w.home_district,w.recruit_point);
  UPDATE pulso_v3.enrollments SET status='revoked',revision=revision+1 WHERE enrollments.id=e.id;
  PERFORM pulso_v3.log(u,'enrollment.revoked',e.id,NULL,'{}');RETURN jsonb_build_object('id',e.id,'revoked',true);
 END IF;
 -- Anonymous clients never call this SQL function; the Edge validates token format and applies IP limits.
 IF p_step IN('claim','auth_record','ready','native_link') THEN
  claim:=p_data->>'claim_hash';IF length(claim)<>64 OR claim IS NULL THEN RAISE EXCEPTION 'V3_INVALID_CLAIM';END IF;
  SELECT * INTO e FROM pulso_v3.enrollments WHERE token_hash=p_data->>'token_hash' FOR UPDATE;
  IF e.id IS NULL OR e.expires_at<clock_timestamp() OR e.status IN('revoked','completed') THEN RAISE EXCEPTION 'V3_INVITE_UNAVAILABLE';END IF;
  SELECT * INTO w FROM pulso_v3.people WHERE people.id=e.person_id;
  PERFORM pulso_v3.require_cap(e.creator_id,'recruit',w.home_district,w.recruit_point);
  IF w.approval IN('suspended','retired') THEN RAISE EXCEPTION 'V3_PERSON_UNAVAILABLE';END IF;
  IF e.claim_hash IS NOT NULL AND e.claim_hash<>claim THEN RAISE EXCEPTION 'V3_INVITE_ALREADY_CLAIMED';END IF;
  IF p_step='claim' THEN
   PERFORM pulso_v3.rate_limit('claim:'||e.id::text,12);
   IF e.status='issued' THEN UPDATE pulso_v3.enrollments SET status='claimed',claim_hash=claim,claim_at=clock_timestamp(),revision=revision+1 WHERE enrollments.id=e.id RETURNING * INTO e;END IF;
   SELECT * INTO pr FROM pulso_v3.provision_requests WHERE enrollment_id=e.id FOR UPDATE;
   lockid:=(p_data->>'lock_id')::uuid;
   IF lockid IS NULL THEN RAISE EXCEPTION 'V3_INVALID_CLAIM';END IF;
   IF pr.lock_until>clock_timestamp() AND pr.lock_id IS DISTINCT FROM lockid THEN RAISE EXCEPTION 'V3_ENROLLMENT_BUSY';END IF;
   UPDATE pulso_v3.provision_requests SET lock_id=lockid,lock_until=clock_timestamp()+interval '30 seconds',updated_at=clock_timestamp() WHERE enrollment_id=e.id;
   -- Recover only a server-marked identity belonging to this person, never an arbitrary duplicate email.
   mail:=lower(w.code)||'@pulso-encuestadores.invalid';
   SELECT au.id INTO u FROM auth.users au WHERE lower(au.email)=mail AND au.raw_app_meta_data->>'pulso_v3_person'=w.id::text;
   RETURN jsonb_build_object('enrollment_id',e.id,'person_id',w.id,'email',mail,'display_name',w.display_name,'person_code',w.code,'auth_user_id',coalesce(e.auth_user_id,u),'status',e.status);
  ELSIF p_step='auth_record' THEN
   u:=(p_data->>'auth_user_id')::uuid;
   IF NOT EXISTS(SELECT 1 FROM auth.users au WHERE au.id=u AND au.raw_app_meta_data->>'pulso_v3_person'=w.id::text AND lower(au.email)=lower(w.code)||'@pulso-encuestadores.invalid') THEN RAISE EXCEPTION 'V3_AUTH_ID_MISMATCH';END IF;
   IF e.auth_user_id IS NOT NULL AND e.auth_user_id<>u THEN RAISE EXCEPTION 'V3_AUTH_ID_MISMATCH';END IF;
   UPDATE pulso_v3.enrollments SET auth_user_id=u,status='auth_created',revision=revision+1 WHERE enrollments.id=e.id;
   UPDATE pulso_v3.provision_requests SET auth_user_id=u,stage='auth_created',updated_at=clock_timestamp() WHERE enrollment_id=e.id;
   RETURN jsonb_build_object('auth_user_id',u);
  ELSIF p_step='ready' THEN
   IF e.auth_user_id IS NULL THEN RAISE EXCEPTION 'V3_AUTH_NOT_READY';END IF;
   INSERT INTO pulso_v3.actors(user_id,person_id,code,display_name,role,enrolled)
    VALUES(e.auth_user_id,w.id,w.code,w.display_name,'interviewer',false)
    ON CONFLICT(user_id) DO NOTHING;
   SELECT * INTO a FROM pulso_v3.actors WHERE user_id=e.auth_user_id;
   IF a.person_id<>w.id OR a.role<>'interviewer' OR NOT a.active THEN RAISE EXCEPTION 'V3_ACTOR_MISMATCH';END IF;
   PERFORM pulso_v3.log(e.creator_id,'enrollment.profile_ready',e.id,e.request_id,jsonb_build_object('auth_user_id',e.auth_user_id,'person_id',w.id));
   UPDATE pulso_v3.enrollments SET status='ready',ready_at=clock_timestamp(),revision=revision+1 WHERE enrollments.id=e.id;
   UPDATE pulso_v3.provision_requests SET stage='profile_ready',lock_id=NULL,lock_until=NULL,updated_at=clock_timestamp() WHERE enrollment_id=e.id;
   RETURN jsonb_build_object('ready',true,'email',lower(w.code)||'@pulso-encuestadores.invalid','enrollment_id',e.id);
  ELSE
   IF e.status<>'ready' THEN RAISE EXCEPTION 'V3_ENROLLMENT_NOT_READY';END IF;
   PERFORM pulso_v3.rate_limit('native-link:'||e.id::text,5);
   RETURN jsonb_build_object('email',lower(w.code)||'@pulso-encuestadores.invalid','enrollment_id',e.id);
  END IF;
 END IF;
 RAISE EXCEPTION 'V3_INVALID_ENROLLMENT_STEP';
END $$;
CREATE FUNCTION public.v3_enrollment_complete(p_enrollment uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;e pulso_v3.enrollments;w pulso_v3.people;BEGIN
 a:=pulso_v3.actor();SELECT * INTO e FROM pulso_v3.enrollments WHERE id=p_enrollment FOR UPDATE;
 IF a.role<>'interviewer' OR e.auth_user_id IS DISTINCT FROM a.user_id OR e.person_id IS DISTINCT FROM a.person_id THEN RAISE EXCEPTION 'V3_CLAIM_IDENTITY_MISMATCH' USING ERRCODE='42501';END IF;
 IF e.status='completed' THEN RETURN jsonb_build_object('completed',true);END IF;
 SELECT * INTO w FROM pulso_v3.people WHERE id=e.person_id;
 PERFORM pulso_v3.require_cap(e.creator_id,'recruit',w.home_district,w.recruit_point);
 IF e.status<>'ready' OR e.expires_at<clock_timestamp() THEN RAISE EXCEPTION 'V3_INVITE_UNAVAILABLE';END IF;
 UPDATE pulso_v3.actors SET enrolled=true,revision=revision+1 WHERE user_id=a.user_id;
 UPDATE pulso_v3.enrollments SET status='completed',revision=revision+1 WHERE id=e.id;
 UPDATE pulso_v3.provision_requests SET stage='completed',updated_at=clock_timestamp() WHERE enrollment_id=e.id;
 PERFORM pulso_v3.log(a.user_id,'enrollment.completed',e.id,e.request_id,jsonb_build_object('person_id',w.id));
 RETURN jsonb_build_object('completed',true,'training_required',true);
END $$;
CREATE FUNCTION public.v3_access_service(p_step text,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;r pulso_v3.access_requests;target pulso_v3.actors;w pulso_v3.people;u uuid;req uuid;mail text;
BEGIN
 SELECT * INTO a FROM pulso_v3.actors WHERE user_id=(p_data->>'actor_id')::uuid AND active;
 IF a.user_id IS NULL THEN RAISE EXCEPTION 'V3_ACCOUNT_DISABLED' USING ERRCODE='42501';END IF;
 PERFORM pulso_v3.assert_service_actor(a.user_id,(p_data->>'session_id')::uuid);
 IF p_step IN('reset_check','reset_finish') THEN
  SELECT * INTO target FROM pulso_v3.actors WHERE user_id=(p_data->>'user_id')::uuid;
  IF target.user_id IS NULL OR target.user_id=a.user_id THEN RAISE EXCEPTION 'V3_RESET_DENIED';END IF;
  IF a.role<>'admin' THEN
   IF target.role<>'interviewer' THEN RAISE EXCEPTION 'V3_RESET_DENIED' USING ERRCODE='42501';END IF;
   SELECT * INTO w FROM pulso_v3.people WHERE id=target.person_id;PERFORM pulso_v3.require_cap(a.user_id,'recruit',w.home_district,w.recruit_point);
  END IF;
  IF p_step='reset_finish' THEN
   INSERT INTO pulso_v3.revoked_sessions(session_id,user_id,reason) SELECT id,user_id,'PASSWORD_RESET' FROM auth.sessions WHERE user_id=target.user_id ON CONFLICT(session_id) DO NOTHING;
   UPDATE pulso_v3.capture_grants SET revoked_at=clock_timestamp(),revoked_reason='PASSWORD_RESET' WHERE user_id=target.user_id AND revoked_at IS NULL;
   UPDATE pulso_v3.assignments SET status=CASE WHEN started_at IS NULL THEN 'ended' ELSE 'draining' END,ended_at=coalesce(ended_at,clock_timestamp()),drain_until=coalesce(drain_until,clock_timestamp()+interval '24 hours'),revision=revision+1 WHERE person_id=target.person_id AND status IN('pending','acknowledged','active');
   PERFORM pulso_v3.log(a.user_id,'account.password_reset',target.user_id,NULL,'{}');
  END IF;RETURN jsonb_build_object('user_id',target.user_id,'code',target.code);
 END IF;
 IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 req:=(p_data->>'request_id')::uuid;IF req IS NULL THEN RAISE EXCEPTION 'V3_REQUEST_ID_REQUIRED';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(a.user_id::text||req::text,6));
 SELECT * INTO r FROM pulso_v3.access_requests WHERE actor_id=a.user_id AND request_id=req FOR UPDATE;
 IF p_step='prepare' THEN
  IF r.request_id IS NULL THEN
   IF p_data->>'role' NOT IN('viewer','coordinator','admin') OR p_data->>'code' !~ '^(VIEW|COORD|ADMIN)-[A-Z0-9]{3,12}$' OR char_length(btrim(p_data->>'display_name')) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'V3_INVALID_ACCESS_ACCOUNT';END IF;
   IF EXISTS(SELECT 1 FROM pulso_v3.actors WHERE code=p_data->>'code') THEN RAISE EXCEPTION 'V3_CODE_EXISTS';END IF;
   INSERT INTO pulso_v3.access_requests(actor_id,request_id,code,display_name,role) VALUES(a.user_id,req,p_data->>'code',btrim(p_data->>'display_name'),p_data->>'role') RETURNING * INTO r;
  ELSIF r.code IS DISTINCT FROM p_data->>'code' OR r.role IS DISTINCT FROM p_data->>'role' THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT';END IF;
  SELECT au.id INTO u FROM auth.users au WHERE lower(email)=lower(r.code)||'@pulso-encuestadores.invalid' AND au.raw_app_meta_data->>'pulso_v3_access_request'=req::text;
  RETURN jsonb_build_object('request_id',req,'code',r.code,'role',r.role,'email',lower(r.code)||'@pulso-encuestadores.invalid','auth_user_id',coalesce(r.auth_user_id,u),'state',r.state);
 ELSIF p_step='complete' THEN
  u:=(p_data->>'auth_user_id')::uuid;
  IF r.request_id IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users au WHERE au.id=u AND au.raw_app_meta_data->>'pulso_v3_access_request'=req::text AND lower(email)=lower(r.code)||'@pulso-encuestadores.invalid') THEN RAISE EXCEPTION 'V3_AUTH_ID_MISMATCH';END IF;
  INSERT INTO pulso_v3.actors(user_id,code,display_name,role,enrolled) VALUES(u,r.code,r.display_name,r.role,true) ON CONFLICT(user_id) DO NOTHING;
  IF NOT EXISTS(SELECT 1 FROM pulso_v3.actors WHERE user_id=u AND code=r.code AND role=r.role AND person_id IS NULL) THEN RAISE EXCEPTION 'V3_ACTOR_MISMATCH';END IF;
  UPDATE pulso_v3.access_requests SET state='completed',auth_user_id=u WHERE actor_id=a.user_id AND request_id=req;
  PERFORM pulso_v3.log(a.user_id,'access.created',u,req,jsonb_build_object('role',r.role,'code',r.code));
  RETURN jsonb_build_object('user_id',u,'code',r.code,'role',r.role,'completed',true);
 END IF;
 RAISE EXCEPTION 'V3_INVALID_ACCESS_STEP';
END $$;
REVOKE ALL ON FUNCTION public.v3_enrollment_service(text,jsonb),public.v3_access_service(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_enrollment_service(text,jsonb),public.v3_access_service(text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.v3_enrollment_complete(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_enrollment_complete(uuid) TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pulso_v3 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pulso_v3 TO service_role;
INSERT INTO pulso_v3.schema_versions(version) VALUES(6);

-- 007_v3_cutover.sql
-- Installs preflight and explicit cutover control; does NOT switch operation_mode.

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

-- 008_v3_storage.sql

ALTER TABLE pulso_v3.capture_grants ADD COLUMN last_seen timestamptz,
 ADD COLUMN pending_reported integer CHECK(pending_reported BETWEEN 0 AND 100000),ADD COLUMN pending_reported_at timestamptz;
CREATE FUNCTION public.v3_ping(p_grant uuid,p_pending integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;BEGIN
 a:=pulso_v3.actor();IF p_pending NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION 'V3_INVALID_COUNT';END IF;
 UPDATE pulso_v3.capture_grants SET last_seen=clock_timestamp(),pending_reported=p_pending,pending_reported_at=clock_timestamp()
 WHERE id=p_grant AND user_id=a.user_id AND auth_session_id=(auth.jwt()->>'session_id')::uuid AND revoked_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'V3_GRANT_DENIED' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('server_time',clock_timestamp(),'client_report_only',true);
END $$;
CREATE FUNCTION public.v3_attachment_allowed(p_path text) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;x pulso_v3.attachments;d text;BEGIN
 a:=pulso_v3.actor();SELECT * INTO x FROM pulso_v3.attachments WHERE object_path=p_path;
 IF x.id IS NULL THEN RETURN false;END IF;
 SELECT s.district_id INTO d FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE p.id=x.point_id;
 RETURN a.role='admin' OR (x.created_by=a.user_id AND pulso_v3.can(a.user_id,'manage_points',d,x.point_id));
EXCEPTION WHEN insufficient_privilege THEN RETURN false;
END $$;
CREATE FUNCTION public.v3_attachments(p_point uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;d text;BEGIN
 a:=pulso_v3.actor();SELECT s.district_id INTO d FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE p.id=p_point;
 PERFORM pulso_v3.require_cap(a.user_id,'manage_points',d,p_point);
 RETURN(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM pulso_v3.attachments x WHERE point_id=p_point AND (a.role='admin' OR x.created_by=a.user_id));
END $$;
REVOKE ALL ON FUNCTION public.v3_ping(uuid,integer),public.v3_attachment_allowed(text),public.v3_attachments(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_ping(uuid,integer),public.v3_attachment_allowed(text),public.v3_attachments(uuid) TO authenticated;
-- Supabase Storage is optional in isolated SQL unit tests. Real deployment must include this schema.
DO $$ BEGIN
 IF to_regclass('storage.buckets') IS NOT NULL THEN
  INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('pulso-v3-docs','pulso-v3-docs',false,10485760,ARRAY['application/pdf','image/png','image/jpeg']) ON CONFLICT(id) DO NOTHING;
  CREATE POLICY pulso_v3_docs_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='pulso-v3-docs' AND public.v3_attachment_allowed(name));
  CREATE POLICY pulso_v3_docs_select ON storage.objects FOR SELECT TO authenticated USING(bucket_id='pulso-v3-docs' AND public.v3_attachment_allowed(name));
 END IF;
END $$;
CREATE FUNCTION public.v3_attachment_confirm(p_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;x pulso_v3.attachments;exists_object boolean;BEGIN
 a:=pulso_v3.actor();SELECT * INTO x FROM pulso_v3.attachments WHERE id=p_id FOR UPDATE;
 IF x.id IS NULL OR NOT public.v3_attachment_allowed(x.object_path) THEN RAISE EXCEPTION 'V3_SCOPE_DENIED' USING ERRCODE='42501';END IF;
 IF to_regclass('storage.objects') IS NULL THEN RAISE EXCEPTION 'V3_STORAGE_NOT_INSTALLED';END IF;
 EXECUTE 'SELECT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id=$1 AND name=$2)' INTO exists_object USING 'pulso-v3-docs',x.object_path;
 IF NOT exists_object THEN RAISE EXCEPTION 'V3_UPLOAD_UNCONFIRMED';END IF;
 UPDATE pulso_v3.attachments SET state='uploaded' WHERE id=p_id;
 PERFORM pulso_v3.log(a.user_id,'attachment.confirmed',p_id,NULL,jsonb_build_object('point_id',x.point_id));
 RETURN jsonb_build_object('id',p_id,'state','uploaded');
END $$;
REVOKE ALL ON FUNCTION public.v3_attachment_confirm(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_attachment_confirm(uuid) TO authenticated;
CREATE FUNCTION public.v3_recover_upload(p_grant uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;g pulso_v3.capture_grants;t pulso_v3.assignments;sid uuid;BEGIN
 PERFORM 1 FROM pulso_v3.operations WHERE id=1 FOR SHARE;
 a:=pulso_v3.actor();sid:=(auth.jwt()->>'session_id')::uuid;
 SELECT * INTO g FROM pulso_v3.capture_grants WHERE id=p_grant;
 SELECT * INTO t FROM pulso_v3.assignments WHERE id=g.assignment_id;
 IF a.role<>'interviewer' OR g.user_id IS DISTINCT FROM a.user_id OR t.person_id IS DISTINCT FROM a.person_id THEN RAISE EXCEPTION 'V3_TASK_DENIED' USING ERRCODE='42501';END IF;
 IF t.status='active' AND g.capture_until>clock_timestamp() AND g.revoked_at IS NULL THEN RAISE EXCEPTION 'V3_ACTIVE_TASK_NEEDS_HANDOVER';END IF;
 IF clock_timestamp()>g.upload_until THEN RAISE EXCEPTION 'V3_RECOVERY_EXPIRED';END IF;
 INSERT INTO pulso_v3.upload_recoveries(grant_id,user_id,auth_session_id) VALUES(g.id,a.user_id,sid) ON CONFLICT(grant_id,auth_session_id) DO NOTHING;
 PERFORM pulso_v3.log(a.user_id,'upload.recovery',g.assignment_id,NULL,jsonb_build_object('grant_id',g.id,'review_required',true));
 RETURN jsonb_build_object('grant_id',g.id,'upload_only',true,'review_required',true);
END $$;
CREATE FUNCTION public.v3_finish_my_task(p_assignment uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;t pulso_v3.assignments;o pulso_v3.operations;BEGIN
 SELECT * INTO o FROM pulso_v3.operations WHERE id=1 FOR SHARE;
 a:=pulso_v3.actor();SELECT * INTO t FROM pulso_v3.assignments WHERE id=p_assignment FOR UPDATE;
 IF a.role<>'interviewer' OR t.person_id IS DISTINCT FROM a.person_id THEN RAISE EXCEPTION 'V3_TASK_DENIED' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 5 AND 500 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED';END IF;
 IF t.status IN('draining','ended') THEN RETURN jsonb_build_object('id',t.id,'status',t.status,'duplicate',true);END IF;
 UPDATE pulso_v3.assignments SET status=CASE WHEN started_at IS NULL THEN 'ended' ELSE 'draining' END,
 ended_at=clock_timestamp(),drain_until=clock_timestamp()+make_interval(hours=>o.drain_hours),revision=revision+1 WHERE id=t.id;
 PERFORM pulso_v3.log(a.user_id,'assignment.owner_finished',t.id,NULL,jsonb_build_object('reason',p_reason));
 RETURN jsonb_build_object('id',t.id,'status','draining','new_captures',false);
END $$;
REVOKE ALL ON FUNCTION public.v3_recover_upload(uuid),public.v3_finish_my_task(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_recover_upload(uuid),public.v3_finish_my_task(uuid,text) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(8);

COMMIT;
SELECT version,installed_at FROM pulso_v3.schema_versions ORDER BY version;
SELECT operation_mode FROM public.settings WHERE id=1;
