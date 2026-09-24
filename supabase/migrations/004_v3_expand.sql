-- Pulso V3 / 004: additive expansion only. Does NOT enable V3 or open fieldwork.
-- Preserve migrations 001-003, legacy UUIDs, accounts, survey rows and audit records.
BEGIN;
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
COMMIT;
