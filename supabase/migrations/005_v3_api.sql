-- Pulso V3 / 005: scope-checked RPCs. Private tables have no browser grants.
BEGIN;
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
     JOIN pulso_v3.actors worker_actor ON worker_actor.person_id=w.id
     WHERE x.point_id=id AND x.status IN('acknowledged','active') AND w.approval='approved' AND worker_actor.active AND worker_actor.enrolled) THEN RAISE EXCEPTION 'V3_POINT_NEEDS_ONE_READY_WORKER'; END IF;
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
  -- A point-scoped coordinator must also be permitted to manage the source person.
  PERFORM pulso_v3.require_cap(a.user_id,'assign',per.home_district,per.recruit_point);
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
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN('assignment_id','response_id','candidate_id','outcome','consent','already_voted','started_at','captured_at','time_precision','paper_batch','paper_number','reason')) THEN RAISE EXCEPTION 'V3_INVALID_PAPER_FIELDS';END IF;
  IF jsonb_typeof(p_data->'already_voted') IS DISTINCT FROM 'boolean' OR p_data->'already_voted'<>'true'::jsonb OR jsonb_typeof(p_data->'consent') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'V3_CONSENT_REQUIRED';END IF;
  IF length(reason)<10 OR nullif(p_data->>'paper_batch','') IS NULL OR nullif(p_data->>'paper_number','') IS NULL THEN RAISE EXCEPTION 'V3_PAPER_REFERENCE_REQUIRED'; END IF;
  SELECT * INTO q FROM pulso_v3.questionnaires WHERE questionnaires.id=t.questionnaire_id;
  state:=p_data->>'outcome';id:=(p_data->>'response_id')::uuid;
  IF state='candidate' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(q.items) item WHERE item->>'id'=p_data->>'candidate_id') THEN RAISE EXCEPTION 'V3_CANDIDATE_VERSION_MISMATCH'; END IF;
  IF p_data->>'time_precision' IS NULL OR (p_data->>'time_precision') NOT IN('minutes','interval') THEN RAISE EXCEPTION 'V3_PAPER_TIME_PRECISION'; END IF;
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
 IF e.id IS NULL OR p_offset IS NULL OR p_limit IS NULL OR p_offset<0 OR p_limit NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'V3_INVALID_EXPORT';END IF;
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
COMMIT;
