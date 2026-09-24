BEGIN;
ALTER TABLE pulso_v3.capture_grants ADD COLUMN last_seen timestamptz,
 ADD COLUMN pending_reported integer CHECK(pending_reported BETWEEN 0 AND 100000),ADD COLUMN pending_reported_at timestamptz;
CREATE FUNCTION public.v3_ping(p_grant uuid,p_pending integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a pulso_v3.actors;BEGIN
 a:=pulso_v3.actor();IF p_pending IS NULL OR p_pending NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION 'V3_INVALID_COUNT';END IF;
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
 RETURN jsonb_build_object('id',t.id,'status',CASE WHEN t.started_at IS NULL THEN 'ended' ELSE 'draining' END,'new_captures',false);
END $$;
REVOKE ALL ON FUNCTION public.v3_recover_upload(uuid),public.v3_finish_my_task(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_recover_upload(uuid),public.v3_finish_my_task(uuid,text) TO authenticated;
INSERT INTO pulso_v3.schema_versions(version) VALUES(8);
COMMIT;
