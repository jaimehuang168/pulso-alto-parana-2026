"""Apply reviewed RC-only corrections, never execute against a database."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def replace(path,old,new):
 p=ROOT/path;s=p.read_text()
 if old not in s and new in s:return
 if s.count(old)!=1:raise RuntimeError('Source drift; stop: '+path)
 p.write_text(s.replace(old,new))
replace('supabase/migrations/007_v3_cutover.sql',"char_length(btrim(p_backup_reference))<10 OR char_length(btrim(p_acceptance_reference))<10","char_length(btrim(coalesce(p_backup_reference,''))) NOT BETWEEN 10 AND 2000 OR char_length(btrim(coalesce(p_acceptance_reference,''))) NOT BETWEEN 10 AND 2000")
replace('supabase/migrations/005_v3_api.sql',"IF per.home_district<>d THEN PERFORM pulso_v3.require_cap(a.user_id,'assign',per.home_district,per.recruit_point); END IF;","-- A point-scoped coordinator must also be permitted to manage the source person.\n  PERFORM pulso_v3.require_cap(a.user_id,'assign',per.home_district,per.recruit_point);")
replace('supabase/migrations/005_v3_api.sql',"SELECT 1 FROM pulso_v3.assignments x JOIN pulso_v3.people w ON w.id=x.person_id\n     WHERE x.point_id=id AND x.status IN('acknowledged','active') AND w.approval='approved'","SELECT 1 FROM pulso_v3.assignments x JOIN pulso_v3.people w ON w.id=x.person_id\n     JOIN pulso_v3.actors worker_actor ON worker_actor.person_id=w.id\n     WHERE x.point_id=id AND x.status IN('acknowledged','active') AND w.approval='approved' AND worker_actor.active AND worker_actor.enrolled")
replace('supabase/migrations/005_v3_api.sql',"IF e.id IS NULL OR p_offset<0 OR p_limit NOT BETWEEN 1 AND 500 THEN","IF e.id IS NULL OR p_offset IS NULL OR p_limit IS NULL OR p_offset<0 OR p_limit NOT BETWEEN 1 AND 500 THEN")
replace('supabase/migrations/008_v3_storage.sql',"IF p_pending NOT BETWEEN 0 AND 100000 THEN","IF p_pending IS NULL OR p_pending NOT BETWEEN 0 AND 100000 THEN")
replace('supabase/migrations/008_v3_storage.sql',"RETURN jsonb_build_object('id',t.id,'status','draining','new_captures',false);","RETURN jsonb_build_object('id',t.id,'status',CASE WHEN t.started_at IS NULL THEN 'ended' ELSE 'draining' END,'new_captures',false);")
replace('v3/tests/native.mjs',"assert.equal((await rpc(worker,'v3_bootstrap')).actor.role,'interviewer');});","assert.equal((await rpc(worker,'v3_bootstrap')).actor.role,'interviewer');await rpc(worker,'v3_finish_my_task',{p_assignment:task,p_reason:'End native API task before independent browser assignment'});});")
replace('v3/tests/native.mjs','if(error)throw error;return r;','if(error)throw Object.assign(new Error(error.message),error);return r;')
replace('supabase/migrations/005_v3_api.sql'," WHEN 'paper.submit' THEN\n  IF length(reason)<10",""" WHEN 'paper.submit' THEN
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN('assignment_id','response_id','candidate_id','outcome','consent','already_voted','started_at','captured_at','time_precision','paper_batch','paper_number','reason')) THEN RAISE EXCEPTION 'V3_INVALID_PAPER_FIELDS';END IF;
  IF jsonb_typeof(p_data->'already_voted') IS DISTINCT FROM 'boolean' OR p_data->'already_voted'<>'true'::jsonb OR jsonb_typeof(p_data->'consent') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'V3_CONSENT_REQUIRED';END IF;
  IF length(reason)<10""")
replace('supabase/migrations/005_v3_api.sql',"IF (p_data->>'time_precision') NOT IN('minutes','interval') THEN","IF p_data->>'time_precision' IS NULL OR (p_data->>'time_precision') NOT IN('minutes','interval') THEN")
print('Reviewed source corrections prepared. No production connection or data mutation.')
