-- V3.1 company management: ONE atomic upgrade, no survey insertion or activation.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
-- One company deployment. Super Admin is an application capability, never a database superuser.
DO $$ BEGIN
 IF to_regprocedure('public.v3_live_admin_state()') IS NULL OR to_regprocedure('pulso_v3.command_before_reports(text,jsonb,uuid,bigint,integer)') IS NULL OR
    (SELECT count(*) FROM pulso_v3.schema_versions WHERE version BETWEEN 4 AND 11)<>8
 THEN RAISE EXCEPTION 'V3_COMPANY_BASELINE_REQUIRED'; END IF;
END $$;
CREATE TABLE IF NOT EXISTS pulso_v3.super_admins(
 user_id uuid PRIMARY KEY REFERENCES pulso_v3.actors(user_id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 authorization_reference text NOT NULL CHECK(length(authorization_reference)>=10)
);
ALTER TABLE pulso_v3.super_admins ENABLE ROW LEVEL SECURITY;
CREATE TABLE IF NOT EXISTS pulso_v3.company_profile(
 id integer PRIMARY KEY CHECK(id=1), name text NOT NULL DEFAULT '',
 contact_name text NOT NULL DEFAULT '', support_email text NOT NULL DEFAULT '', support_phone text NOT NULL DEFAULT '',
 notes text NOT NULL DEFAULT '', revision bigint NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(), updated_by uuid REFERENCES auth.users(id)
);
ALTER TABLE pulso_v3.company_profile ENABLE ROW LEVEL SECURITY;
INSERT INTO pulso_v3.company_profile(id) VALUES(1) ON CONFLICT(id) DO NOTHING;
CREATE OR REPLACE FUNCTION pulso_v3.is_super_admin(u uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM pulso_v3.super_admins s JOIN pulso_v3.actors a ON a.user_id=s.user_id
   WHERE s.user_id=u AND a.role='admin' AND a.active AND a.enrolled)
$$;
CREATE OR REPLACE FUNCTION pulso_v3.require_manage_account(actor_id uuid,target_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE t pulso_v3.actors;
BEGIN
 SELECT * INTO t FROM pulso_v3.actors WHERE user_id=target_id;
 IF t.user_id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
 IF EXISTS(SELECT 1 FROM pulso_v3.super_admins WHERE user_id=target_id) THEN
   RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT' USING ERRCODE='42501';
 END IF;
 IF t.role='admin' AND NOT pulso_v3.is_super_admin(actor_id) THEN
   RAISE EXCEPTION 'V3_SUPER_ADMIN_ONLY' USING ERRCODE='42501';
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.v3_company_command(p_action text,p_data jsonb,p_request_id uuid,p_expected bigint DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
DECLARE a pulso_v3.actors; t pulso_v3.actors; w pulso_v3.people; c pulso_v3.company_profile;
 old pulso_v3.command_receipts; h text; id uuid; label text; reason text; result jsonb;
BEGIN
 a:=pulso_v3.actor();
 PERFORM 1 FROM pulso_v3.operations WHERE operations.id=1 FOR UPDATE;
 IF p_action IS NULL OR p_action NOT IN('company.save','actor.rename','person.rename') OR p_request_id IS NULL OR
    jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>16000 THEN RAISE EXCEPTION 'V3_INVALID_COMMAND'; END IF;
 IF p_action IN('company.save','actor.rename') AND a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501'; END IF;
 IF p_action='company.save' THEN
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN('name','contact_name','support_email','support_phone','notes')) THEN RAISE EXCEPTION 'V3_COMPANY_INVALID'; END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN('id','display_name','reason')) THEN RAISE EXCEPTION 'V3_INVALID_COMMAND'; END IF;
  id:=(p_data->>'id')::uuid;label:=btrim(p_data->>'display_name');reason:=btrim(p_data->>'reason');
  IF id IS NULL OR label IS NULL OR length(label) NOT BETWEEN 1 AND 100 OR reason IS NULL OR length(reason) NOT BETWEEN 10 AND 500 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED'; END IF;
  IF p_action='actor.rename' THEN
   SELECT * INTO t FROM pulso_v3.actors WHERE user_id=id;
   IF t.user_id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
   IF id<>a.user_id THEN PERFORM pulso_v3.require_manage_account(a.user_id,id); END IF;
  ELSE
   SELECT * INTO w FROM pulso_v3.people WHERE people.id=id;
   IF w.id IS NULL THEN RAISE EXCEPTION 'V3_NOT_FOUND'; END IF;
   PERFORM pulso_v3.require_cap(a.user_id,'recruit',w.home_district,w.recruit_point);
  END IF;
 END IF;
 h:=pulso_v3.hash(jsonb_build_object('action',p_action,'data',p_data,'expected',p_expected));
 PERFORM pg_advisory_xact_lock(hashtextextended(a.user_id::text||p_request_id::text,3));
 SELECT * INTO old FROM pulso_v3.command_receipts WHERE actor_id=a.user_id AND request_id=p_request_id;
 IF FOUND THEN
  IF old.payload_hash<>h THEN RAISE EXCEPTION 'V3_IDEMPOTENCY_CONFLICT';END IF;
  RETURN old.result||jsonb_build_object('duplicate',true);
 END IF;
 IF p_action='company.save' THEN
  SELECT * INTO c FROM pulso_v3.company_profile WHERE company_profile.id=1 FOR UPDATE;
  PERFORM pulso_v3.require_revision(c.revision,p_expected);
  IF p_data->>'name' IS NULL OR length(btrim(p_data->>'name')) NOT BETWEEN 1 AND 160 OR
     length(coalesce(p_data->>'contact_name',''))>100 OR length(coalesce(p_data->>'support_email',''))>254 OR
     length(coalesce(p_data->>'support_phone',''))>60 OR length(coalesce(p_data->>'notes',''))>2000 OR
     (coalesce(p_data->>'support_email','')<>'' AND p_data->>'support_email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
   THEN RAISE EXCEPTION 'V3_COMPANY_INVALID'; END IF;
  UPDATE pulso_v3.company_profile SET name=btrim(p_data->>'name'),contact_name=btrim(coalesce(p_data->>'contact_name','')),
    support_email=btrim(coalesce(p_data->>'support_email','')),support_phone=btrim(coalesce(p_data->>'support_phone','')),
    notes=coalesce(p_data->>'notes',''),revision=revision+1,updated_at=clock_timestamp(),updated_by=a.user_id WHERE company_profile.id=1;
  result:=jsonb_build_object('saved',true,'revision',c.revision+1);
  PERFORM pulso_v3.log(a.user_id,p_action,NULL,p_request_id,jsonb_build_object('old',to_jsonb(c)-'updated_by','new',p_data));
 ELSIF p_action='actor.rename' THEN
  PERFORM pulso_v3.require_revision(t.revision,p_expected);
  UPDATE pulso_v3.actors SET display_name=label,revision=revision+1 WHERE user_id=id;
  IF t.person_id IS NOT NULL THEN UPDATE pulso_v3.people SET display_name=label,revision=revision+1 WHERE people.id=t.person_id; END IF;
  result:=jsonb_build_object('id',id,'revision',t.revision+1);
  PERFORM pulso_v3.log(a.user_id,p_action,id,p_request_id,jsonb_build_object('old_name',t.display_name,'new_name',label,'reason',reason));
 ELSE
  PERFORM pulso_v3.require_revision(w.revision,p_expected);
  UPDATE pulso_v3.people SET display_name=label,revision=revision+1 WHERE people.id=id;
  UPDATE pulso_v3.actors SET display_name=label,revision=revision+1 WHERE person_id=id;
  result:=jsonb_build_object('id',id,'revision',w.revision+1);
  PERFORM pulso_v3.log(a.user_id,p_action,id,p_request_id,jsonb_build_object('old_name',w.display_name,'new_name',label,'reason',reason));
 END IF;
 INSERT INTO pulso_v3.command_receipts(actor_id,request_id,action,payload_hash,capability,result) VALUES(a.user_id,p_request_id,p_action,h,CASE WHEN p_action='person.rename' THEN 'recruit' ELSE 'admin' END,result);
 PERFORM pulso_v3.signal(NULL);RETURN result;
END $$;

CREATE OR REPLACE FUNCTION pulso_v3.command_before_reports(p_action text,p_data jsonb,p_request_id uuid,p_expected bigint DEFAULT 0,p_client integer DEFAULT 30000)
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
 -- V3.1: hierarchy is read from a private database registry, never browser claims.
 IF p_action IN('actor.disable','actor.enable','actor.promote') THEN
   PERFORM pulso_v3.require_manage_account(a.user_id,id);
   IF p_action='actor.promote' AND (p_data->>'role')='admin' THEN
     RAISE EXCEPTION 'V3_CREATE_ADMIN_SEPARATELY' USING ERRCODE='42501';
   END IF;
 END IF;
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
  IF id=a.user_id OR pulso_v3.is_super_admin(id) THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;
  PERFORM pulso_v3.require_revision(other.revision,p_expected);IF length(reason)<10 THEN RAISE EXCEPTION 'V3_REASON_REQUIRED';END IF;
  -- Old sessions are not restored: a new login is required after reactivation.
  INSERT INTO pulso_v3.revoked_sessions(session_id,user_id,reason) SELECT ss.id,ss.user_id,'ACCOUNT_REENABLED_RELOGIN' FROM auth.sessions ss WHERE ss.user_id=other.user_id ON CONFLICT(session_id) DO NOTHING;
  UPDATE pulso_v3.actors SET active=true,revision=revision+1 WHERE user_id=id;
 WHEN 'actor.disable' THEN
  IF id=a.user_id OR pulso_v3.is_super_admin(id) THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;
  PERFORM pulso_v3.require_revision(other.revision,p_expected);
  UPDATE pulso_v3.actors SET active=false,revision=revision+1 WHERE user_id=id;
  UPDATE pulso_v3.capture_grants SET revoked_at=now_at,revoked_reason='ACCOUNT_DISABLED' WHERE user_id=id AND revoked_at IS NULL;
 WHEN 'actor.promote' THEN
  -- Only existing verified Auth identities can receive elevated roles. Enrollment cannot self-promote.
  SELECT * INTO other FROM pulso_v3.actors WHERE user_id=id;IF other.user_id IS NULL OR other.role='interviewer' OR id=a.user_id THEN RAISE EXCEPTION 'V3_PROTECTED_ACCOUNT'; END IF;
  PERFORM pulso_v3.require_revision(other.revision,p_expected);state:=p_data->>'role';
  IF state IS NULL OR state NOT IN('viewer','coordinator') OR length(reason)<10 THEN RAISE EXCEPTION 'V3_INVALID_ROLE'; END IF;
  UPDATE pulso_v3.actors SET role=state,revision=revision+1 WHERE user_id=id;
  -- No prior scope silently reappears when a role is changed back.
  UPDATE pulso_v3.role_grants SET revoked_at=now_at,revision=revision+1 WHERE user_id=id AND revoked_at IS NULL;
  INSERT INTO pulso_v3.revoked_sessions(session_id,user_id,reason)
    SELECT ss.id,ss.user_id,'ROLE_CHANGED_RELOGIN' FROM auth.sessions ss WHERE ss.user_id=id ON CONFLICT(session_id) DO NOTHING;
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
CREATE OR REPLACE FUNCTION public.v3_access_service(p_step text,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;r pulso_v3.access_requests;target pulso_v3.actors;w pulso_v3.people;u uuid;req uuid;mail text;
BEGIN
 SELECT * INTO a FROM pulso_v3.actors WHERE user_id=(p_data->>'actor_id')::uuid AND active;
 IF a.user_id IS NULL THEN RAISE EXCEPTION 'V3_ACCOUNT_DISABLED' USING ERRCODE='42501';END IF;
 PERFORM pulso_v3.assert_service_actor(a.user_id,(p_data->>'session_id')::uuid);
 -- Check stored request as well as input: an old in-progress admin request cannot bypass the gate.
 IF p_step IN('prepare','complete') AND ((p_data->>'role')='admin' OR EXISTS(
   SELECT 1 FROM pulso_v3.access_requests ar WHERE ar.actor_id=a.user_id
   AND ar.request_id=(p_data->>'request_id')::uuid AND ar.role='admin')) THEN
   IF NOT pulso_v3.is_super_admin(a.user_id) THEN RAISE EXCEPTION 'V3_SUPER_ADMIN_ONLY' USING ERRCODE='42501'; END IF;
 END IF;
 IF p_step IN('reset_check','reset_finish') THEN
  PERFORM pulso_v3.require_manage_account(a.user_id,(p_data->>'user_id')::uuid);
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
   IF p_data->>'role' IS NULL OR p_data->>'code' IS NULL OR p_data->>'display_name' IS NULL OR p_data->>'role' NOT IN('viewer','coordinator','admin') OR p_data->>'code' !~ '^(VIEW|COORD|ADMIN)-[A-Z0-9]{3,12}$' OR char_length(btrim(p_data->>'display_name')) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'V3_INVALID_ACCESS_ACCOUNT';END IF;
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
CREATE OR REPLACE FUNCTION public.v3_bootstrap(p_client integer DEFAULT 30000) RETURNS jsonb
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
  'actor',to_jsonb(a)||jsonb_build_object('is_super_admin',pulso_v3.is_super_admin(a.user_id)),'operation',CASE WHEN a.role='admin' THEN to_jsonb(o) ELSE jsonb_build_object('title',o.title,'contest',o.contest,'fieldwork_date',o.fieldwork_date,'phase',o.phase,'viewer_enabled',o.viewer_enabled,'minimum_client',o.minimum_client,'revision',o.revision,'lease_minutes',o.lease_minutes) END,
  'operation_mode',mode,'server_time',statement_timestamp(),'schema_version',12,'company_schema_version',12,'company',(SELECT CASE WHEN a.role='admin' THEN to_jsonb(c) ELSE jsonb_build_object('name',c.name,'support_email',c.support_email,'support_phone',c.support_phone) END FROM pulso_v3.company_profile c WHERE c.id=1),
  'districts',(SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.sort_order),'[]') FROM public.districts d WHERE a.role='admin' OR public.v3_can_read_signal(d.id) OR pulso_v3.can(a.user_id,'view_results',d.id,NULL)),
  'grants',(SELECT coalesce(jsonb_agg(to_jsonb(g)),'[]') FROM pulso_v3.role_grants g WHERE (a.role='admin' OR g.user_id=a.user_id)),
  'points',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.code),'[]') FROM permitted_points p),
  'stations',(SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.code),'[]') FROM pulso_v3.stations s WHERE a.role='admin' OR s.id IN(SELECT station_id FROM permitted_points) OR pulso_v3.can(a.user_id,'manage_points',s.district_id,NULL)),
  'people',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.code),'[]') FROM permitted_people p),
  'assignments',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC),'[]') FROM permitted_tasks t),
  'actors',(SELECT coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('is_super_admin',pulso_v3.is_super_admin(x.user_id)) ORDER BY x.code),'[]') FROM pulso_v3.actors x WHERE a.role='admin' OR (a.role='coordinator' AND x.role='interviewer' AND x.person_id IN(SELECT id FROM permitted_people))),
  'questionnaires',(SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.district_id,q.version DESC),'[]') FROM pulso_v3.questionnaires q WHERE a.role='admin' OR
    (a.role='coordinator' AND q.state='published' AND EXISTS(SELECT 1 FROM permitted_points p JOIN pulso_v3.stations s ON s.id=p.station_id WHERE s.district_id=q.district_id)) OR q.id IN(SELECT questionnaire_id FROM permitted_tasks WHERE person_id=a.person_id)),
  'enrollments',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'person_id',e.person_id,'status',e.status,'expires_at',e.expires_at,'auth_user_id',e.auth_user_id,'revision',e.revision)),'[]') FROM pulso_v3.enrollments e WHERE a.role='admin' OR (a.role='coordinator' AND e.creator_id=a.user_id))
 ) INTO result;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.v3_activate(p_legacy_outbox_handled boolean,p_backup_reference text,p_acceptance_reference text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;r record;mode text;
BEGIN
 a:=pulso_v3.actor();IF NOT pulso_v3.is_super_admin(a.user_id) THEN RAISE EXCEPTION 'V3_SUPER_ADMIN_ONLY' USING ERRCODE='42501';END IF;IF a.role<>'admin' THEN RAISE EXCEPTION 'V3_ADMIN_ONLY' USING ERRCODE='42501';END IF;
 SELECT operation_mode INTO mode FROM public.settings WHERE id=1 FOR UPDATE;
 IF mode='v3' THEN RETURN jsonb_build_object('active',true,'duplicate',true);END IF;
 IF p_legacy_outbox_handled IS DISTINCT FROM true OR char_length(btrim(coalesce(p_backup_reference,''))) NOT BETWEEN 10 AND 2000 OR char_length(btrim(coalesce(p_acceptance_reference,''))) NOT BETWEEN 10 AND 2000
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

-- Company management replaces legacy account mutation even while global cutover is pending.
-- Provision-team reads profiles with service_role before any Auth write: deny that old gateway.
REVOKE ALL ON TABLE public.profiles FROM PUBLIC,anon,service_role;
DO $legacy_account_gate$ DECLARE f regprocedure; BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname IN('set_account_active','set_assignment','set_operator_label') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',f);
 END LOOP;
END $legacy_account_gate$;
REVOKE ALL ON TABLE pulso_v3.super_admins,pulso_v3.company_profile FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION pulso_v3.is_super_admin(uuid),pulso_v3.require_manage_account(uuid,uuid),public.v3_company_command(text,jsonb,uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_company_command(text,jsonb,uuid,bigint) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(12) ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';

-- Application owner: explicit user request. No password or Auth user is created or changed.
DO $$
DECLARE u uuid; matches integer;
BEGIN
 SELECT count(*),(array_agg(id))[1] INTO matches,u FROM auth.users
 WHERE lower(email)='jaimehuang168@gmail.com' AND email_confirmed_at IS NOT NULL;
 IF matches<>1 OR NOT EXISTS(SELECT 1 FROM pulso_v3.actors WHERE user_id=u AND role='admin' AND active AND enrolled AND person_id IS NULL)
 THEN RAISE EXCEPTION 'V3_JAIME_VERIFIED_ADMIN_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pulso_v3.super_admins WHERE user_id=u) THEN
  INSERT INTO pulso_v3.super_admins(user_id,authorization_reference)
    VALUES(u,'Owner explicitly designated by jaimehuang168: V3.1 company administration request');
  PERFORM pulso_v3.log(u,'governance.super_admin_designated',u,NULL,jsonb_build_object('basis','Explicit owner request; not a backup or acceptance attestation'));
 END IF;
END $$;

COMMIT;
