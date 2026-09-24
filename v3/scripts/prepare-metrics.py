"""Expand already scoped read models; prepare source files only."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'supabase/migrations/005_v3_api.sql';s=p.read_text()
old="SELECT r.* FROM pulso_v3.responses r WHERE (a.role='admin' OR r.person_id=a.person_id)"
new="""SELECT r.*,person.code AS person_code,person.display_name AS person_name,
   st.name AS station_name,pt.label AS point_label,
   (SELECT item->>'name' FROM jsonb_array_elements(q.items) item WHERE item->>'id'=r.candidate_id::text) AS candidate_name,
   (SELECT item->>'list' FROM jsonb_array_elements(q.items) item WHERE item->>'id'=r.candidate_id::text) AS candidate_list
  FROM pulso_v3.responses r JOIN pulso_v3.people person ON person.id=r.person_id
  JOIN pulso_v3.points pt ON pt.id=r.point_id JOIN pulso_v3.stations st ON st.id=pt.station_id
  JOIN pulso_v3.questionnaires q ON q.id=r.questionnaire_id WHERE (a.role='admin' OR r.person_id=a.person_id)"""
if old in s:
 assert s.count(old)==1;s=s.replace(old,new)
else: assert new in s
old="'active_workers',(SELECT count(*) FROM pulso_v3.assignments t WHERE t.point_id=p.id AND t.status='active'),"
new="""'active_workers',(SELECT count(*) FROM pulso_v3.assignments t JOIN pulso_v3.people w ON w.id=t.person_id JOIN pulso_v3.actors aa ON aa.person_id=w.id WHERE t.point_id=p.id AND t.status='active' AND w.approval='approved' AND aa.active AND aa.enrolled),
    'accepted',(SELECT count(*) FROM rs r WHERE r.point_id=p.id AND r.disposition='accepted'),
    'pending_review',(SELECT count(*) FROM rs r WHERE r.point_id=p.id AND r.disposition='pending_review'),
    'excluded',(SELECT count(*) FROM rs r WHERE r.point_id=p.id AND r.disposition='excluded'),
    'windows',(SELECT coalesce(jsonb_agg(jsonb_build_object('opened_at',w.opened_at,'closed_at',w.closed_at) ORDER BY w.opened_at),'[]') FROM pulso_v3.point_windows w WHERE w.point_id=p.id),
    'candidate_base',CASE WHEN a.role='admin' THEN (SELECT count(*) FROM rs r JOIN pulso_v3.questionnaires q ON q.id=r.questionnaire_id WHERE r.point_id=p.id AND r.disposition='accepted' AND r.outcome='candidate' AND q.state='published') END,
    'candidates',CASE WHEN a.role='admin' THEN (SELECT coalesce(jsonb_agg(item||jsonb_build_object('count',(SELECT count(*) FROM rs r WHERE r.point_id=p.id AND r.questionnaire_id=q.id AND r.disposition='accepted' AND r.candidate_id=(item->>'id')::uuid))),'[]') FROM pulso_v3.questionnaires q CROSS JOIN LATERAL jsonb_array_elements(q.items) item WHERE q.district_id=p.district_id AND q.state='published') END,
    'hours',(SELECT coalesce(jsonb_agg(jsonb_build_object('hour',h.hour,'count',h.n) ORDER BY h.hour),'[]') FROM (SELECT date_trunc('hour',r.captured_at) AS hour,count(*) AS n FROM rs r WHERE r.point_id=p.id GROUP BY date_trunc('hour',r.captured_at)) h),"""
if old in s:
 assert s.count(old)==1;s=s.replace(old,new)
else: assert new in s
p.write_text(s)
p=R/'v3/web/modules/views.mjs';s=p.read_text()
if "import {pointMetrics}" not in s:
 s="import {pointMetrics} from './metrics.mjs';\n"+s
 s=s.replace('export function overview(S){','function overviewBase(S){',1)
 s+='\nexport function overview(S){return overviewBase(S)+pointMetrics(S);}\n'
 s=s.replace("${E(OUTCOMES[r.outcome])} · ${E(r.candidate_id||'')}","${E(r.candidate_name||OUTCOMES[r.outcome])} ${E(r.candidate_list||'')}")
 s=s.replace("<small>${time(r.captured_at)} → ${time(r.received_at)} · ${E(r.source)}</small>","<small>${E(r.person_code||'')} · ${E(r.station_name||'')} · ${E(r.point_label||'')}</small><small>${time(r.captured_at)} → ${time(r.received_at)} · ${E(r.source)}</small>")
 p.write_text(s)
p=R/'v3/web/styles.css';s=p.read_text()
if '.point-metrics{' not in s:
 p.write_text(s+'\n.point-metrics{border-top:1px solid var(--line,#dbe5e8);padding:18px 0}.point-metrics summary{display:flex;flex-wrap:wrap;gap:12px;align-items:center;cursor:pointer;font-size:18px}.point-metrics summary strong{flex:1;min-width:160px;overflow-wrap:anywhere}.point-metrics small{display:block}.point-metrics .stats{margin-top:12px}\n')
p=R/'v3/tests/database.mjs';s=p.read_text()
marker="await check('Coordinator sees operations but no candidate counts'"
if "Scoped point detail and immutable candidate labels" not in s:
 start=s.index(marker)
 s=s[:start]+"""await check('Scoped point detail and immutable candidate labels',async()=>{const d=await rpc('v3_dashboard'),p=d.points.find(x=>x.id===point);assert.equal(p.accepted,1);assert.equal(p.candidate_base,1);assert.equal(p.active_workers,1);assert.equal(p.candidates[0].count,1);assert.equal(p.windows.length,1);assert.equal(p.hours.reduce((n,h)=>n+h.count,0),1);const rec=await rpc('v3_records');assert.equal(rec[0].candidate_name,'Candidatura DEMO A');assert.equal(rec[0].station_name,'Centro QA sintético');const scoped=await rpc('v3_dashboard',[],co,cs);assert.equal(scoped.points.length,1);assert.equal(scoped.points[0].candidates,null);assert.equal(scoped.points[0].candidate_base,null);});
"""+s[start:]
 p.write_text(s)
print('Read-model detail prepared; permissions and ingestion controls remain unchanged.')
