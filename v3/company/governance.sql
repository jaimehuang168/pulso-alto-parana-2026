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
