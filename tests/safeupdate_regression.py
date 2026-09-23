"""Disposable PostgreSQL regression; never accepts a production DSN or writes live data."""
from pathlib import Path
import hashlib
import json
import os
import uuid
import psycopg2
from psycopg2.extras import Json

ROOT = Path.cwd()
OLD = 'update public.district_signals set version=version+1,changed_at=clock_timestamp();'
NEW = 'update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id in (select id from public.districts);'
patch = (ROOT/'supabase/migrations/003_safeupdate_compatibility.sql').read_text()
fixed = (ROOT/'supabase/00_INSTALL_NEW_PROJECT.sql').read_text()
original = fixed.replace(NEW, OLD)
TABLES = ['districts','settings','candidates','stations','profiles','responses','audit_log','district_signals']
FUNCS = ['set_account_active','set_viewer_access','save_settings','set_fieldwork_state']
results = []

def connect(db):
    if db not in ('postgres','pulso_safe_legacy','pulso_safe_fresh'):
        raise ValueError('Only disposable CI databases are permitted.')
    return psycopg2.connect(host='127.0.0.1', port=5432, dbname=db,
        user='postgres', password='pulso-safe-ci-only', connect_timeout=10)

def query(sql, args=None, *, db='pulso_safe_legacy', actor=None, role=None, safe=True):
    c = connect(db)
    try:
        c.autocommit = True
        with c.cursor() as q:
            if safe:
                q.execute("LOAD 'safeupdate'")
                q.execute('SHOW safeupdate.enabled')
                assert q.fetchone()[0] == 'on'
            if actor is not None or role is not None:
                c.autocommit = False
                q.execute('SET LOCAL ROLE '+('anon' if role == 'anon' else 'authenticated'))
                q.execute("select set_config('request.jwt.claim.sub',%s,true)",(actor or '',))
            q.execute(sql,args)
            rows=q.fetchall() if q.description else None
            if not c.autocommit:c.commit()
            return rows
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

def check(name, condition):
    if not condition:raise AssertionError(name)
    results.append({'name':name,'pass':True})
    print('PASS',name,flush=True)

def denied(sql,args=None,*,actor=None,role=None,code='42501',message=None):
    try:query(sql,args,actor=actor,role=role)
    except psycopg2.Error as e:
        return e.pgcode==code and (message is None or message in str(e))
    return False

def table_snapshot():
    return {t:query('select coalesce(jsonb_agg(x order by x::text),\'[]\'::jsonb) from (select to_jsonb(r) x from public.'+t+' r) v')[0][0] for t in TABLES}

def function_snapshot():
    return query("select p.proname,p.oid,p.proowner,p.proacl::text,p.prosecdef,p.proconfig,pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(%s) order by p.proname",(FUNCS,))

query('create role anon nologin;create role authenticated nologin;create role service_role nologin bypassrls;',db='postgres',safe=False)
for db in ('pulso_safe_legacy','pulso_safe_fresh'):
    query('create database '+db,db='postgres',safe=False)
    query("create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to anon,authenticated,service_role;create publication supabase_realtime;",db=db,safe=False)
query(original,safe=False)
query(fixed,db='pulso_safe_fresh')
check('Fresh installer succeeds with actual safeupdate ON',query('select (select count(*) from public.districts),(select count(*) from public.candidates),(select count(*) from public.responses)',db='pulso_safe_fresh')[0]==(4,12,0))
query(patch,db='pulso_safe_fresh')
check('Upgrade is also valid after the corrected fresh installer',True)
admin=str(uuid.uuid4());viewer=str(uuid.uuid4())
for uid,email in [(admin,'admin@example.invalid'),(viewer,'viewer@example.invalid')]:
    query('insert into auth.users values(%s,%s)',(uid,email))
query("insert into public.profiles(id,code,role,district_id) values(%s,'COORD-01','admin',null),(%s,'VIEW-QA001','viewer','cde')",(admin,viewer))
query("update public.candidates set name='TEST '||id::text,is_template=false where district_id in(select id from public.districts);update public.stations set is_template=false,address='CI ONLY address',point_label='CI ONLY point' where district_id in(select id from public.districts);update public.settings set fieldwork_date=(clock_timestamp() at time zone 'America/Asuncion')::date,catalog_confirmed=true,methodology='CI ONLY — sample test protocol, not a real survey' where id=1;")
for district,prefix in [('cde','CDE'),('minga','MGA'),('hernandarias','HER'),('franco','PFR')]:
    st=query('select id from public.stations where district_id=%s order by id limit 1',(district,))[0][0]
    for slot in range(1,16):
        uid=str(uuid.uuid4())
        query('insert into auth.users values(%s,%s)',(uid,uid+'@example.invalid'))
        query("insert into public.profiles(id,code,role,district_id,station_id,slot) values(%s,%s,'interviewer',%s,%s,%s)",(uid,f'{prefix}-{slot:02}',district,st,slot))
settings=query('select to_jsonb(s) from public.settings s where id=1')[0][0]
snapshot=table_snapshot()
for name,sql,args in [
 ('account disable','select public.set_account_active(%s,false)',(viewer,)),
 ('viewer switch','select public.set_viewer_access(true)',None),
 ('settings save','select public.save_settings(%s)',(Json(settings),)),
 ('fieldwork open',"select public.set_fieldwork_state('open')",None)
]:
    check('Original reproduces WHERE error: '+name,denied(sql,args,actor=admin,code='21000',message='UPDATE requires a WHERE clause'))
check('Failed original operations roll back table changes and audit rows',table_snapshot()==snapshot)
f_before=function_snapshot()
query(patch)
f_after=function_snapshot()
check('Upgrade changes only the intended notification SQL in four functions',all(a[:-1]==b[:-1] and a[-1].replace(OLD,NEW)==b[-1] for a,b in zip(f_before,f_after)) and len(f_after)==4)
check('Upgrade leaves all eight tables unchanged',table_snapshot()==snapshot)
query(patch)
check('Repeated upgrade preserves data and definitions',table_snapshot()==snapshot and function_snapshot()==f_after)
check('All eight tables retain RLS',query("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=any(%s) and c.relrowsecurity",(TABLES,))[0][0]==8)
check('Anonymous cannot disable accounts',denied('select public.set_account_active(%s,false)',(viewer,),role='anon'))
check('Viewer cannot disable accounts',denied('select public.set_account_active(%s,false)',(admin,),actor=viewer))
check('Admin cannot disable self',denied('select public.set_account_active(%s,false)',(admin,),actor=admin,code='23514'))
check('Null active flag is refused',denied('select public.set_account_active(%s,null)',(viewer,),actor=admin,code='23514'))
signal_before=query('select district_id,version from public.district_signals order by district_id')
query('select public.set_account_active(%s,false)',(viewer,),actor=admin)
check('Admin disables the viewer with safeupdate ON',query('select active from public.profiles where id=%s',(viewer,))[0][0] is False)
check('Disable keeps a committed audit row',query("select count(*) from public.audit_log where action='account_access_changed' and subject_id=%s and detail->>'active'='false'",(viewer,))[0][0]==1)
signal_after=query('select district_id,version from public.district_signals order by district_id')
check('Four configured city notification counters advance once',len(signal_after)==4 and all(a[0]==b[0] and a[1]+1==b[1] for a,b in zip(signal_before,signal_after)))
check('Disabled viewer cannot bootstrap',denied('select public.bootstrap()',actor=viewer))
query('select public.set_account_active(%s,true)',(viewer,),actor=admin)
check('Admin can reactivate viewer without changing role or city',query('select active,role,district_id from public.profiles where id=%s',(viewer,))[0]==(True,'viewer','cde'))
query('select public.set_viewer_access(true)',actor=admin)
check('Viewer switch succeeds with safeupdate ON',query('select viewer_enabled from public.settings where id=1')[0][0] is True)
query('select public.set_viewer_access(false)',actor=admin)
check('Viewer switch can be closed again',query('select viewer_enabled from public.settings where id=1')[0][0] is False)
query('select public.save_settings(%s)',(Json(settings),),actor=admin)
check('Settings save succeeds with safeupdate ON',query("select count(*) from public.audit_log where action='settings_saved'")[0][0]==1)
query("select public.set_fieldwork_state('open')",actor=admin)
check('Validated CI fieldwork opens with safeupdate ON',query('select state from public.settings where id=1')[0][0]=='open')
check('Settings lock remains after opening',denied('select public.save_settings(%s)',(Json(settings),),actor=admin,code='P0001'))
query("select public.set_fieldwork_state('closed')",actor=admin)
check('CI fieldwork closes with safeupdate ON',query('select state from public.settings where id=1')[0][0]=='closed')
check('Closed fieldwork cannot be reopened',denied("select public.set_fieldwork_state('open')",actor=admin,code='P0001'))
check('All tests add zero survey responses',query('select count(*) from public.responses')[0][0]==0)
check('Safety still blocks unqualified UPDATE',denied('update public.district_signals set version=version+1',code='21000',message='UPDATE requires a WHERE clause'))
check('Safety still blocks unqualified DELETE',denied('delete from public.responses',code='21000',message='DELETE requires a WHERE clause'))
report={'scope':'Disposable PostgreSQL 17 with real pg-safeupdate 1.7 ON. Auth identity is a CI test double. No live Supabase connection.','source_commit':os.environ.get('GITHUB_SHA'),'postgres':query('select version()')[0][0],'passed':len(results),'tests':results,'migration_sha256':hashlib.sha256(patch.encode()).hexdigest()}
Path('audit-results').mkdir(exist_ok=True)
Path('audit-results/safeupdate-regression.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('SAFEUPDATE_REGRESSION_SUMMARY',json.dumps(report,ensure_ascii=False),flush=True)
