-- Individual admin-issued accounts for personally owned phones. No passwords in SQL.
-- This is an additive upgrade; it never opens fieldwork, changes dates or inserts responses.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $$ BEGIN
 IF (SELECT count(*) FROM pulso_v3.schema_versions WHERE version BETWEEN 4 AND 14)<>11
 OR to_regprocedure('public.v3_installation_status()') IS NULL THEN RAISE EXCEPTION 'V3_SIMPLE_BASELINE_REQUIRED'; END IF;
END $$;
ALTER TABLE pulso_v3.people ADD COLUMN IF NOT EXISTS onboarding_mode text NOT NULL DEFAULT 'guided'
 CHECK(onboarding_mode IN('guided','admin_managed'));
ALTER TABLE pulso_v3.assignments ADD COLUMN IF NOT EXISTS acknowledgement_mode text NOT NULL DEFAULT 'interviewer'
 CHECK(acknowledgement_mode IN('interviewer','admin_assignment','automatic_login'));
DO $$ DECLARE c record; BEGIN
 -- Replace only the original training-dependent approval constraint, preserving every other check.
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='pulso_v3.people'::regclass
  AND contype='c' AND conname='people_check' AND pg_get_constraintdef(oid) LIKE '%training_passed_at%' AND pg_get_constraintdef(oid) LIKE '%training_practice_ack%'
  AND conname<>'people_approval_basis' LOOP
   EXECUTE format('ALTER TABLE pulso_v3.people DROP CONSTRAINT %I',c.conname);
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='pulso_v3.people'::regclass AND conname='people_approval_basis') THEN
  ALTER TABLE pulso_v3.people ADD CONSTRAINT people_approval_basis CHECK(approval<>'approved' OR
   (approved_by IS NOT NULL AND ((training_passed_at IS NOT NULL AND training_practice_ack) OR onboarding_mode='admin_managed')));
 END IF;
END $$;
CREATE TABLE IF NOT EXISTS pulso_v3.simple_accounts(
 actor_id uuid NOT NULL REFERENCES pulso_v3.actors(user_id),request_id uuid NOT NULL,
 person_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),code text NOT NULL UNIQUE,
 display_name text NOT NULL,district_id text NOT NULL REFERENCES public.districts(id),
 point_id uuid REFERENCES pulso_v3.points(id),payload_hash text NOT NULL,
 auth_user_id uuid REFERENCES auth.users(id),state text NOT NULL DEFAULT 'prepared' CHECK(state IN('prepared','completed')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),completed_at timestamptz,
 PRIMARY KEY(actor_id,request_id)
);
ALTER TABLE pulso_v3.simple_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pulso_v3.simple_accounts FROM PUBLIC,anon,authenticated;
GRANT ALL ON pulso_v3.simple_accounts TO service_role;

CREATE OR REPLACE FUNCTION public.v3_simple_account_service(p_step text,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
DECLARE a pulso_v3.actors;r pulso_v3.simple_accounts;u uuid;req uuid;pt uuid;d text;nm text;code text;h text;mail text;q uuid;t uuid;
BEGIN
 IF p_step IS NULL OR p_step NOT IN('prepare','complete') OR p_data IS NULL OR jsonb_typeof(p_data)<>'object'
 OR octet_length(p_data::text)>4000 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k
  WHERE k NOT IN('actor_id','session_id','request_id','code','display_name','district_id','point_id','auth_user_id'))
 THEN RAISE EXCEPTION 'V3_INVALID_REQUEST';END IF;
 SELECT * INTO a FROM pulso_v3.actors WHERE user_id=(p_data->>'actor_id')::uuid AND active AND enrolled;
 IF a.user_id IS NULL THEN RAISE EXCEPTION 'V3_ACCOUNT_DISABLED' USING ERRCODE='42501';END IF;
 PERFORM pulso_v3.assert_service_actor(a.user_id,(p_data->>'session_id')::uuid);
 IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 req:=(p_data->>'request_id')::uuid;code:=upper(btrim(p_data->>'code'));nm:=btrim(p_data->>'display_name');
 d:=p_data->>'district_id';pt:=nullif(p_data->>'point_id','')::uuid;
 IF req IS NULL OR code IS NULL OR code!~ '^ENC-[A-Z0-9][A-Z0-9-]{2,30}$'
 OR nm IS NULL OR char_length(nm) NOT BETWEEN 1 AND 100 OR d IS NULL
 OR NOT EXISTS(SELECT 1 FROM public.districts WHERE id=d) THEN RAISE EXCEPTION 'V3_INVALID_INTERVIEWER';END IF;
 IF pt IS NOT NULL AND NOT EXISTS(SELECT 1 FROM pulso_v3.points p JOIN pulso_v3.stations s ON s.id=p.station_id
 WHERE p.id=pt AND s.district_id=d) THEN RAISE EXCEPTION 'V3_POINT_DISTRICT_MISMATCH';END IF;
 h:=pulso_v3.hash(jsonb_build_object('code',code,'name',nm,'district',d,'point',pt));
 PERFORM pg_advisory_xact_lock(hashtextextended('simple-account:'||code,15));
 SELECT * INTO r FROM pulso_v3.simple_accounts WHERE actor_id=a.user_id AND request_id=req FOR UPDATE;
 IF r.request_id IS NOT NULL AND r.payload_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT';END IF;
 mail:=lower(code)||'@pulso-encuestadores.invalid';
 IF p_step='prepare' THEN
  IF r.request_id IS NULL THEN
   IF EXISTS(SELECT 1 FROM pulso_v3.people WHERE people.code=code)
   OR EXISTS(SELECT 1 FROM pulso_v3.actors WHERE actors.code=code)
   OR EXISTS(SELECT 1 FROM auth.users WHERE lower(email)=mail)
   OR EXISTS(SELECT 1 FROM pulso_v3.simple_accounts WHERE simple_accounts.code=code)
   THEN RAISE EXCEPTION 'V3_CODE_EXISTS';END IF;
   INSERT INTO pulso_v3.simple_accounts(actor_id,request_id,code,display_name,district_id,point_id,payload_hash)
    VALUES(a.user_id,req,code,nm,d,pt,h) RETURNING * INTO r;
  END IF;
  -- Recover only a server-marked Auth identity for this exact actor, request and person.
  SELECT au.id INTO u FROM auth.users au WHERE lower(au.email)=mail
   AND au.raw_app_meta_data->>'pulso_simple_request'=req::text
   AND au.raw_app_meta_data->>'pulso_simple_creator'=a.user_id::text
   AND au.raw_app_meta_data->>'pulso_simple_person'=r.person_id::text;
  RETURN jsonb_build_object('request_id',req,'person_id',r.person_id,'code',code,'email',mail,
   'auth_user_id',coalesce(r.auth_user_id,u),'state',r.state);
 END IF;
 u:=(p_data->>'auth_user_id')::uuid;
 IF r.request_id IS NULL OR u IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users au WHERE au.id=u AND lower(au.email)=mail
   AND au.email_confirmed_at IS NOT NULL AND au.raw_app_meta_data->>'pulso_simple_request'=req::text
   AND au.raw_app_meta_data->>'pulso_simple_creator'=a.user_id::text
   AND au.raw_app_meta_data->>'pulso_simple_person'=r.person_id::text)
 THEN RAISE EXCEPTION 'V3_AUTH_ID_MISMATCH';END IF;
 IF r.state='completed' THEN
  IF r.auth_user_id IS DISTINCT FROM u THEN RAISE EXCEPTION 'V3_AUTH_ID_MISMATCH';END IF;
  RETURN jsonb_build_object('completed',true,'duplicate',true,'user_id',u,'person_id',r.person_id,'code',code);
 END IF;
 -- Administrative work authorization is NOT a fabricated training completion.
 INSERT INTO pulso_v3.people(id,code,display_name,home_district,recruit_point,created_by,
  onboarding_mode,approval,approved_by,approved_at)
 VALUES(r.person_id,code,nm,d,pt,a.user_id,'admin_managed','approved',a.user_id,clock_timestamp());
 INSERT INTO pulso_v3.actors(user_id,person_id,code,display_name,role,enrolled)
 VALUES(u,r.person_id,code,nm,'interviewer',true);
 IF pt IS NOT NULL THEN
  SELECT id INTO q FROM pulso_v3.questionnaires WHERE district_id=d AND state='published';
  IF q IS NOT NULL AND EXISTS(SELECT 1 FROM pulso_v3.points WHERE id=pt AND state IN('approved','open','paused')) THEN
   INSERT INTO pulso_v3.assignments(person_id,point_id,questionnaire_id,created_by,status,acknowledged_at,acknowledgement_mode,reason)
   VALUES(r.person_id,pt,q,a.user_id,'acknowledged',clock_timestamp(),'admin_assignment','Asignación al crear cuenta individual') RETURNING id INTO t;
  END IF;
 END IF;
 UPDATE pulso_v3.simple_accounts SET state='completed',auth_user_id=u,completed_at=clock_timestamp()
 WHERE actor_id=a.user_id AND request_id=req;
 PERFORM pulso_v3.log(a.user_id,'interviewer.created',u,req,jsonb_build_object('person_id',r.person_id,'code',code,
  'district',d,'point_id',pt,'assignment_id',t,'approval_basis','admin_account_creation','training_completed',false));
 PERFORM pulso_v3.signal(d);
 RETURN jsonb_build_object('completed',true,'user_id',u,'person_id',r.person_id,'code',code,'assignment_id',t,'role','interviewer');
END $$;
REVOKE ALL ON FUNCTION public.v3_simple_account_service(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_simple_account_service(text,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.v3_start_task(p_assignment uuid,p_device uuid,p_client integer DEFAULT 30000) RETURNS jsonb
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
 IF o.phase<>'running' OR o.fieldwork_date<>(now_at AT TIME ZONE 'America/Asuncion')::date OR w.approval<>'approved' OR (w.onboarding_mode<>'admin_managed' AND NOT w.training_practice_ack) THEN RAISE EXCEPTION 'V3_NOT_READY';END IF;
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
CREATE OR REPLACE FUNCTION public.v3_prepare_interviewer(p_device uuid,p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;w pulso_v3.people;o pulso_v3.operations;t pulso_v3.assignments;
 p pulso_v3.points;q pulso_v3.questionnaires;g pulso_v3.capture_grants;sid uuid;d text;now_at timestamptz:=clock_timestamp();
BEGIN
 SELECT * INTO o FROM pulso_v3.operations WHERE id=1 FOR SHARE;
 a:=pulso_v3.actor();sid:=(auth.jwt()->>'session_id')::uuid;
 IF a.role<>'interviewer' OR NOT a.enrolled OR p_device IS NULL THEN RAISE EXCEPTION 'V3_WORKER_ONLY' USING ERRCODE='42501';END IF;
 IF p_client IS NULL OR p_client<o.minimum_client THEN RAISE EXCEPTION 'V3_UPDATE_REQUIRED';END IF;
 IF (SELECT operation_mode FROM public.settings WHERE id=1)<>'v3' THEN RETURN jsonb_build_object('status','waiting_setup');END IF;
 SELECT * INTO w FROM pulso_v3.people WHERE id=a.person_id FOR UPDATE;
 IF w.approval<>'approved' THEN RETURN jsonb_build_object('status','waiting_admin');END IF;
 IF w.onboarding_mode<>'admin_managed' AND (w.training_passed_at IS NULL OR NOT w.training_practice_ack)
 THEN RETURN jsonb_build_object('status','waiting_admin');END IF;
 SELECT * INTO t FROM pulso_v3.assignments WHERE person_id=w.id AND status IN('pending','acknowledged','active')
 ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'acknowledged' THEN 1 ELSE 2 END,created_at DESC,id LIMIT 1 FOR UPDATE;
 IF t.id IS NULL AND w.onboarding_mode='admin_managed' AND w.recruit_point IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM pulso_v3.assignments WHERE person_id=w.id) THEN
  SELECT * INTO p FROM pulso_v3.points WHERE id=w.recruit_point;
  SELECT s.district_id INTO d FROM pulso_v3.stations s WHERE s.id=p.station_id;
  SELECT * INTO q FROM pulso_v3.questionnaires WHERE district_id=d AND state='published';
  IF q.id IS NOT NULL AND p.state IN('approved','open','paused') THEN
   INSERT INTO pulso_v3.assignments(person_id,point_id,questionnaire_id,created_by,status,acknowledged_at,acknowledgement_mode,reason)
   VALUES(w.id,p.id,q.id,w.approved_by,'acknowledged',now_at,'admin_assignment','Preparación de la asignación indicada por administración') RETURNING * INTO t;
   PERFORM pulso_v3.log(a.user_id,'assignment.prepared_from_admin',t.id,NULL,jsonb_build_object('admin_id',w.approved_by,'physical_location_verified',false));
   PERFORM pulso_v3.signal(d);
  ELSE RETURN jsonb_build_object('status',CASE WHEN q.id IS NULL THEN 'waiting_questionnaire' ELSE 'waiting_point' END);END IF;
 END IF;
 IF t.id IS NULL THEN RETURN jsonb_build_object('status','waiting_assignment');END IF;
 SELECT * INTO p FROM pulso_v3.points WHERE id=t.point_id FOR SHARE;
 SELECT * INTO q FROM pulso_v3.questionnaires WHERE id=t.questionnaire_id;
 IF t.status='pending' THEN
  UPDATE pulso_v3.assignments SET status='acknowledged',acknowledged_at=now_at,acknowledgement_mode='automatic_login',revision=revision+1
   WHERE id=t.id RETURNING * INTO t;
  PERFORM pulso_v3.log(a.user_id,'assignment.auto_prepared',t.id,NULL,jsonb_build_object('physical_location_verified',false));
  PERFORM pulso_v3.signal(q.district_id);
 END IF;
 IF o.phase<>'running' OR o.fieldwork_date<>(now_at AT TIME ZONE 'America/Asuncion')::date
 THEN RETURN jsonb_build_object('status','waiting_start','assignment',to_jsonb(t));END IF;
 IF p.state<>'open' THEN RETURN jsonb_build_object('status','waiting_point','assignment',to_jsonb(t));END IF;
 IF q.state<>'published' THEN RETURN jsonb_build_object('status','waiting_questionnaire','assignment',to_jsonb(t));END IF;
 -- Authenticated same person may resume the existing task on the same browser device.
 -- A different device remains blocked. Revoked grants are not restored here.
 IF t.status='active' AND t.active_session_id IS DISTINCT FROM sid THEN
  SELECT * INTO g FROM pulso_v3.capture_grants WHERE assignment_id=t.id AND user_id=a.user_id
    AND device_id=p_device AND revoked_at IS NULL AND upload_until>now_at ORDER BY issued_at DESC LIMIT 1;
  IF g.id IS NULL THEN RAISE EXCEPTION 'V3_DEVICE_IN_USE';END IF;
  INSERT INTO pulso_v3.upload_recoveries(grant_id,user_id,auth_session_id)
   SELECT id,a.user_id,sid FROM pulso_v3.capture_grants WHERE assignment_id=t.id AND user_id=a.user_id
    AND device_id=p_device AND revoked_at IS NULL AND upload_until>now_at ON CONFLICT DO NOTHING;
  UPDATE pulso_v3.assignments SET active_session_id=sid,revision=revision+1 WHERE id=t.id RETURNING * INTO t;
  PERFORM pulso_v3.log(a.user_id,'task.same_device_reauthenticated',t.id,NULL,jsonb_build_object('old_data_requires_review',true));
 END IF;
 SELECT * INTO g FROM pulso_v3.capture_grants WHERE assignment_id=t.id AND user_id=a.user_id
  AND auth_session_id=sid AND revoked_at IS NULL AND capture_until>now_at+interval '5 minutes' ORDER BY issued_at DESC LIMIT 1;
 IF g.id IS NOT NULL AND g.device_id<>p_device THEN RAISE EXCEPTION 'V3_DEVICE_IN_USE';END IF;
 IF t.status='active' AND g.id IS NOT NULL THEN
  RETURN jsonb_build_object('status','ready','pack',jsonb_build_object('assignment',to_jsonb(t),'grant',to_jsonb(g),
   'questionnaire',to_jsonb(q),'point',to_jsonb(p),'station',(SELECT to_jsonb(s) FROM pulso_v3.stations s WHERE id=p.station_id),
   'server_time',now_at,'minimum_client',o.minimum_client));
 END IF;
 RETURN jsonb_build_object('status','ready','pack',public.v3_start_task(t.id,p_device,p_client));
END $$;
REVOKE ALL ON FUNCTION public.v3_prepare_interviewer(uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_prepare_interviewer(uuid,integer) TO authenticated;
DO $$ BEGIN
 IF to_regprocedure('pulso_v3.bootstrap_before_simple(integer)') IS NULL THEN
  ALTER FUNCTION public.v3_bootstrap(integer) RENAME TO bootstrap_before_simple;
  ALTER FUNCTION public.bootstrap_before_simple(integer) SET SCHEMA pulso_v3;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.v3_bootstrap(p_client integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN RETURN pulso_v3.bootstrap_before_simple(p_client)||jsonb_build_object('simple_login_version',15);END $$;
REVOKE ALL ON FUNCTION pulso_v3.bootstrap_before_simple(integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.v3_bootstrap(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_bootstrap(integer) TO authenticated;

-- Restore managed workers through the existing revision-checked, audited admin command.
-- Retain every other operation and the external-report wrapper unchanged.
DO $managed_restore$
DECLARE definition text; old_check text:='IF per.training_passed_at IS NULL OR NOT per.training_practice_ack OR length(reason)<5 THEN';
 new_check text:='IF (per.onboarding_mode<>''admin_managed'' AND (per.training_passed_at IS NULL OR NOT per.training_practice_ack)) OR length(reason)<5 OR (per.onboarding_mode=''admin_managed'' AND a.role<>''admin'') THEN';
BEGIN
 SELECT pg_get_functiondef('pulso_v3.command_before_reports(text,jsonb,uuid,bigint,integer)'::regprocedure) INTO definition;
 IF strpos(definition,old_check)>0 THEN
  IF length(definition)-length(replace(definition,old_check,''))<>length(old_check) THEN RAISE EXCEPTION 'V3_SIMPLE_COMMAND_LAYOUT';END IF;
  EXECUTE replace(definition,old_check,new_check);
 ELSIF strpos(definition,new_check)=0 THEN RAISE EXCEPTION 'V3_SIMPLE_COMMAND_LAYOUT';END IF;
END $managed_restore$;
REVOKE ALL ON FUNCTION public.v3_start_task(uuid,uuid,integer) FROM PUBLIC,anon;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pulso_v3 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pulso_v3 TO service_role;
INSERT INTO pulso_v3.schema_versions(version) VALUES(15) ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
SELECT EXISTS(SELECT 1 FROM pulso_v3.schema_versions WHERE version=15) AS simple_login_installed,
 (SELECT operation_mode FROM public.settings WHERE id=1) AS operation_mode,
 (SELECT phase FROM pulso_v3.operations WHERE id=1) AS fieldwork_phase,
 false AS fieldwork_opened_by_this_upgrade;
