-- Pulso V3 / 006: service-only account saga and one-claimant enrollment.
BEGIN;
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
COMMIT;
