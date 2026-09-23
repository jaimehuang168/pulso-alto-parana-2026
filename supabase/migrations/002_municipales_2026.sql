-- Pulso 2.0 — run after 001, in a dedicated project BEFORE fieldwork.
-- Refuses to replace a catalogue containing observations. No automatic deletion.
begin;
do $$begin
 if exists(select 1 from public.responses) or exists(select 1 from public.settings where state<>'setup') then
  raise exception 'V2 requiere una jornada vacía en preparación. No se modificaron datos. Use un proyecto nuevo o planifique una migración.';
 end if;
end$$;
alter table public.settings add column viewer_enabled boolean not null default false;
alter table public.profiles add column display_name text not null default '' check(char_length(display_name)<=100);
do $$declare c record; begin
 for c in select conname from pg_constraint where conrelid='public.profiles'::regclass and contype='c' and pg_get_constraintdef(oid) like '%role%' loop
  execute format('alter table public.profiles drop constraint %I',c.conname);
 end loop;
end$$;
update public.profiles set role='viewer' where role='supervisor';
alter table public.profiles add constraint profiles_role_v2 check(role in ('admin','viewer','interviewer'));
alter table public.profiles add constraint profiles_shape_v2 check(
 (role='admin' and district_id is null and station_id is null and slot is null) or
 (role='viewer' and station_id is null and slot is null) or
 (role='interviewer' and district_id is not null and station_id is not null and slot is not null and slot between 1 and 15));
alter table public.stations
 add column code text not null default '' check(char_length(code)<=60),
 add column address text not null default '' check(char_length(address)<=250),
 add column point_label text not null default '' check(char_length(point_label)<=150),
 add column latitude double precision check(latitude between -90 and 90),
 add column longitude double precision check(longitude between -180 and 180),
 add constraint station_coordinate_pair check((latitude is null)=(longitude is null));
alter table public.responses
 add column started_at timestamptz,
 add column station_name_snapshot text not null default '',
 add column station_address_snapshot text not null default '',
 add column point_snapshot text not null default '',
 add column geo_status text not null default 'not_requested' check(geo_status in ('not_requested','granted','denied','unavailable','stale')),
 add column latitude double precision check(latitude between -90 and 90),
 add column longitude double precision check(longitude between -180 and 180),
 add column accuracy_m double precision check(accuracy_m between 0 and 100000),
 add column geo_captured_at timestamptz,
 add constraint response_geo_v2 check((geo_status='granted' and latitude is not null and longitude is not null and accuracy_m is not null and geo_captured_at is not null) or
 (geo_status<>'granted' and latitude is null and longitude is null and accuracy_m is null and geo_captured_at is null)),
 add constraint response_start_v2 check(started_at is null or (started_at<=captured_at and started_at>=captured_at-interval '2 hours'));
create index responses_captured_v2 on public.responses(district_id,station_id,captured_at) where voided_at is null;
create index responses_journal_v2 on public.responses(received_at desc,id desc);

-- Catalogue supplied by the operator on 22 September 2026. Not certified by TSJE.
delete from public.candidates where district_id in (select id from public.districts);
insert into public.candidates(district_id,name,list_label,sort_order,is_template) values
('cde','Rigo Chamorro','Lista 1',0,false),('cde','Dani Mujica','Lista 123',1,false),
('hernandarias','Oscar “Melli” González','Lista 1',0,false),('hernandarias','José Castillo','Lista 2026',1,false),
('minga','César Paredes','Lista 1',0,false),('minga','Mónica Ramírez','Lista 123',1,false),
('minga','Roberto Almiron','Lista 6',2,false),('minga','Tania Mabel Meza','Lista 44',3,false),
('franco','Arnold Ramírez','Lista 1',0,false),('franco','Roya Torres','Lista 2',1,false),
('franco','Henry González','Lista 3',2,false),('franco','Mabel Otazú','Lista 123',3,false);
update public.settings set title='Municipales 2026 · Alto Paraná',contest='Intendencia municipal',fieldwork_date='2026-10-04',catalog_confirmed=false where id=1;
-- Existing sample stations MUST be replaced/renamed with verified real data.

create or replace function app_private.has_access_to(d text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and
 (p.role='admin' or (p.role='interviewer' and p.district_id=d) or
 (p.role='viewer' and (p.district_id is null or p.district_id=d) and (select viewer_enabled from public.settings where id=1))))$$;
drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using((app_private.active_profile()).id is not null and (id=auth.uid() or app_private.is_admin()));

create or replace function public.bootstrap() returns jsonb
language plpgsql stable security definer set search_path='' as $$declare p public.profiles;begin
 p:=app_private.active_profile();if p.id is null then raise exception 'Cuenta no habilitada.' using errcode='42501';end if;
 return jsonb_build_object('profile',to_jsonb(p),'settings',(select to_jsonb(s) from public.settings s where id=1),
 'districts',(select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order),'[]'::jsonb) from public.districts d where p.role='admin' or (p.role='viewer' and p.district_id is null) or d.id=p.district_id),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from public.candidates c where c.active and (p.role='admin' or (p.role='viewer' and p.district_id is null) or c.district_id=p.district_id)),
 'stations',(select coalesce(jsonb_agg(to_jsonb(s) order by s.name),'[]'::jsonb) from public.stations s where s.active and (p.role='admin' or (p.role='viewer' and p.district_id is null) or s.district_id=p.district_id)));
end$$;

create function public.submit_response_v2(p_event jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare rid uuid; uid uuid; oldrow public.responses; st public.stations; started timestamptz; captured timestamptz;
 gs text; lat double precision; lon double precision; acc double precision; gt timestamptz;
begin
 if (app_private.active_profile()).role is distinct from 'interviewer' then raise exception 'Solo encuestadores activos.' using errcode='42501';end if;
 rid:=(p_event->>'id')::uuid;
 if rid is null then raise exception 'Falta identificador.' using errcode='23514';end if;
 -- Serialize retries of the SAME UUID, including their location metadata.
 perform pg_advisory_xact_lock(hashtextextended(rid::text,0));
 started:=(p_event->>'started_at')::timestamptz;captured:=(p_event->>'captured_at')::timestamptz;
 gs:=coalesce(p_event->>'geo_status','not_requested');lat:=(p_event->>'latitude')::double precision;lon:=(p_event->>'longitude')::double precision;
 acc:=(p_event->>'accuracy_m')::double precision;gt:=(p_event->>'geo_captured_at')::timestamptz;
 if started is null or captured is null or started>captured or started<captured-interval '2 hours' then raise exception 'Hora de inicio inválida.' using errcode='23514';end if;
 if gs not in ('not_requested','granted','denied','unavailable','stale') then raise exception 'Estado GPS inválido.' using errcode='23514';end if;
 if gs='granted' then
  if lat is null or lon is null or acc is null or gt is null or not(lat between -90 and 90) or not(lon between -180 and 180) or not(acc between 0 and 100000) or gt>captured+interval '30 seconds' or gt<captured-interval '15 minutes' then raise exception 'Ubicación operativa inválida o antigua.' using errcode='23514';end if;
 elsif lat is not null or lon is not null or acc is not null or gt is not null then raise exception 'GPS no autorizado: no envíe coordenadas.' using errcode='23514';end if;
 select * into oldrow from public.responses where id=rid;
 if found and (oldrow.started_at is distinct from started or oldrow.geo_status is distinct from gs or oldrow.latitude is distinct from lat or oldrow.longitude is distinct from lon or oldrow.accuracy_m is distinct from acc or oldrow.geo_captured_at is distinct from gt) then raise exception 'UUID repetido con metadatos distintos.' using errcode='23514';end if;
 -- v1 validates DB-owned role, date, consent, candidate/district and assigned station;
 -- it also compares every original field for idempotent retries.
 uid:=public.submit_response(rid,(p_event->>'station_id')::uuid,p_event->>'outcome',(p_event->>'candidate_id')::uuid,captured,(p_event->>'consent')::boolean,(p_event->>'already_voted')::boolean);
 if oldrow.id is null then
  select * into st from public.stations where id=(p_event->>'station_id')::uuid;
  update public.responses set started_at=started,station_name_snapshot=st.name,station_address_snapshot=st.address,point_snapshot=st.point_label,geo_status=gs,latitude=lat,longitude=lon,accuracy_m=acc,geo_captured_at=gt where id=uid;
 end if;
 return uid;
end$$;
-- No client can bypass v2 validation through the legacy RPC.
revoke execute on function public.submit_response(uuid,uuid,text,uuid,timestamptz,boolean,boolean) from public,anon,authenticated;

create function public.get_dashboard_v2(p_station_id uuid default null,p_from timestamptz default null,p_to timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$declare p public.profiles;result jsonb;begin
 p:=app_private.active_profile();
 if p.id is null or p.role not in ('admin','viewer') then raise exception 'Panel reservado a administradores y viewers.' using errcode='42501';end if;
 if p.role='viewer' and not(select viewer_enabled from public.settings where id=1) then raise exception 'Acceso viewer aún no habilitado por administración.' using errcode='42501';end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Intervalo inválido.' using errcode='23514';end if;
 if p_station_id is not null and not exists(select 1 from public.stations s where s.id=p_station_id and s.active and app_private.has_access_to(s.district_id)) then raise exception 'Local fuera de su alcance.' using errcode='42501';end if;
 with allowed as (select d.* from public.districts d where app_private.has_access_to(d.id) and (p_station_id is null or d.id=(select district_id from public.stations where id=p_station_id))),
 rr as materialized(select r.* from public.responses r join allowed d on d.id=r.district_id where r.voided_at is null and (p_station_id is null or r.station_id=p_station_id) and (p_from is null or r.captured_at>=p_from) and (p_to is null or r.captured_at<=p_to)),
 dc as(select district_id,count(*) total,count(*) filter(where outcome<>'refused') answered,count(*) filter(where outcome='candidate') valid,count(*) filter(where outcome='blank') blank,count(*) filter(where outcome='invalid') invalid,count(*) filter(where outcome='undisclosed') undisclosed,count(*) filter(where outcome='refused') refused from rr group by district_id),
 cc as(select candidate_id,count(*) n from rr where outcome='candidate' group by candidate_id),
 ac as(select agent_id,count(*) n,max(received_at) last_received,max(captured_at) last_captured from rr group by agent_id),
 sc as(select station_id,count(*) n,count(*) filter(where outcome<>'refused') answered,count(*) filter(where outcome='candidate') valid,max(received_at) last_received from rr group by station_id),
 hc as(select district_id,date_trunc('hour',received_at) AS hour,count(*) n from rr group by district_id,date_trunc('hour',received_at)),
 ch as(select district_id,date_trunc('hour',captured_at) AS hour,count(*) n from rr group by district_id,date_trunc('hour',captured_at))
 select jsonb_build_object('generated_at',statement_timestamp(),'settings',(select to_jsonb(s) from public.settings s where id=1),'filters',jsonb_build_object('station_id',p_station_id,'from',p_from,'to',p_to),
 'districts',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'name',d.name,'target_agents',15,
 'total',coalesce(dc.total,0),'answered',coalesce(dc.answered,0),'valid',coalesce(dc.valid,0),'blank',coalesce(dc.blank,0),'invalid',coalesce(dc.invalid,0),'undisclosed',coalesce(dc.undisclosed,0),'refused',coalesce(dc.refused,0),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('count',coalesce(cc.n,0)) order by c.sort_order),'[]'::jsonb) from public.candidates c left join cc on cc.candidate_id=c.id where c.district_id=d.id and c.active),
 'agents',case when p.role='admin' then (select coalesce(jsonb_agg(to_jsonb(pr)||jsonb_build_object('count',coalesce(ac.n,0),'last_received',ac.last_received,'last_captured',ac.last_captured) order by pr.slot),'[]'::jsonb) from public.profiles pr left join ac on ac.agent_id=pr.id where pr.district_id=d.id and pr.role='interviewer' and (p_station_id is null or pr.station_id=p_station_id)) else '[]'::jsonb end,
 'stations',(select coalesce(jsonb_agg(to_jsonb(st)||jsonb_build_object('count',coalesce(sc.n,0),'answered',coalesce(sc.answered,0),'valid',coalesce(sc.valid,0),'last_received',sc.last_received,
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('count',(select count(*) from rr where station_id=st.id and candidate_id=c.id)) order by c.sort_order),'[]'::jsonb) from public.candidates c where c.district_id=d.id and c.active)) order by st.name),'[]'::jsonb) from public.stations st left join sc on sc.station_id=st.id where st.district_id=d.id and st.active and (p_station_id is null or st.id=p_station_id)),
 'hours',(select coalesce(jsonb_agg(jsonb_build_object('hour',hc.hour,'count',hc.n) order by hc.hour),'[]'::jsonb) from hc where hc.district_id=d.id),
 'capture_hours',(select coalesce(jsonb_agg(jsonb_build_object('hour',ch.hour,'count',ch.n) order by ch.hour),'[]'::jsonb) from ch where ch.district_id=d.id)
 ) order by d.sort_order) from allowed d left join dc on dc.district_id=d.id),'[]'::jsonb)) into result;
 return result;
end$$;
create or replace function public.get_dashboard() returns jsonb language sql stable security definer set search_path='' as $$select public.get_dashboard_v2()$$;

create function public.get_records_v2(p_district_id text default null,p_station_id uuid default null,p_agent_id uuid default null,p_before timestamptz default null,p_before_id uuid default null,p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path='' as $$declare p public.profiles;result jsonb;begin
 p:=app_private.active_profile();if p.id is null or p.role not in ('admin','interviewer') then raise exception 'Registro reservado a administración o capturas propias.' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'Límite inválido.' using errcode='23514';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Cursor incompleto.' using errcode='23514';end if;
 if p.role='interviewer' then
  if (p_agent_id is not null and p_agent_id<>p.id) or (p_district_id is not null and p_district_id<>p.district_id) or (p_station_id is not null and p_station_id<>p.station_id) then raise exception 'Solo capturas propias.' using errcode='42501';end if;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.received_at desc,x.id desc),'[]'::jsonb) into result from
 (select r.*,pr.code agent_code,pr.display_name agent_name,st.code station_code,c.name candidate_name,c.list_label
 from public.responses r join public.profiles pr on pr.id=r.agent_id join public.stations st on st.id=r.station_id left join public.candidates c on c.id=r.candidate_id
 where (p.role='admin' or r.agent_id=p.id) and (p_district_id is null or r.district_id=p_district_id) and (p_station_id is null or r.station_id=p_station_id) and (p_agent_id is null or r.agent_id=p_agent_id)
 and (p_before is null or (r.received_at,r.id)<(p_before,p_before_id)) order by r.received_at desc,r.id desc limit p_limit) x;
 return result;
end$$;

create function public.list_accounts_v2() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(to_jsonb(p) order by p.role,p.code),'[]'::jsonb) from public.profiles p);
end$$;
create function public.set_viewer_access(p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 if p_enabled is null then raise exception 'Valor inválido.' using errcode='23514';end if;
 update public.settings set viewer_enabled=p_enabled,updated_at=clock_timestamp() where id=1;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'viewer_access_changed',jsonb_build_object('enabled',p_enabled));
 update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id in (select id from public.districts);
end$$;
create function public.set_operator_label(p_user_id uuid,p_name text) returns void language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 update public.profiles set display_name=btrim(p_name) where id=p_user_id;
 if not found then raise exception 'Cuenta no encontrada.';end if;
 insert into public.audit_log(actor_id,action,subject_id) values(auth.uid(),'operator_label_changed',p_user_id);
end$$;
create or replace function public.set_account_active(p_user_id uuid,p_active boolean) returns void
language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 if p_user_id=auth.uid() or p_active is null then raise exception 'Operación no permitida.' using errcode='23514';end if;
 update public.profiles set active=p_active where id=p_user_id and role in ('interviewer','viewer');
 if not found then raise exception 'Cuenta no encontrada o protegida.' using errcode='P0001';end if;
 insert into public.audit_log(actor_id,action,subject_id,detail) values(auth.uid(),'account_access_changed',p_user_id,jsonb_build_object('active',p_active));
 update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id in (select id from public.districts);
end$$;

create or replace function public.save_catalog(p_district_id text,p_candidates jsonb,p_stations jsonb) returns void
language plpgsql security definer set search_path=''
as $$declare s public.settings; item jsonb; cid uuid; sid uuid; kept_c uuid[]:='{}'; kept_s uuid[]:='{}'; nm text; lb text; ord integer:=0; begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 select * into s from public.settings where id=1 for update;
 if s.state<>'setup' or exists(select 1 from public.responses) then raise exception 'No se puede modificar un catálogo con una jornada iniciada.' using errcode='P0001'; end if;
 if not exists(select 1 from public.districts where id=p_district_id) then raise exception 'Distrito inválido.' using errcode='23514'; end if;
 if jsonb_typeof(p_candidates) is distinct from 'array' or jsonb_array_length(p_candidates) not between 2 and 12 or jsonb_typeof(p_stations) is distinct from 'array' or jsonb_array_length(p_stations) not between 1 and 200 then raise exception 'Se requieren 2–12 candidaturas y 1–200 locales.' using errcode='23514'; end if;
 -- Deactivate names first so rename/swap operations are transactional, not order-sensitive.
 update public.candidates set active=false where district_id=p_district_id;
 for item in select value from jsonb_array_elements(p_candidates) loop
   cid:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid()); nm:=btrim(coalesce(item->>'name','')); lb:=btrim(coalesce(item->>'list_label',''));
   if exists(select 1 from public.candidates where id=cid and district_id<>p_district_id) or cid=any(kept_c) then raise exception 'Identificador de candidatura inválido o repetido.' using errcode='23514'; end if;
   insert into public.candidates(id,district_id,name,list_label,sort_order,active,is_template)
     values(cid,p_district_id,nm,lb,ord,true,(nm||' '||lb)~*'(ejemplo|configurar|pendiente)' or nm~*'^candidatura [abc]$')
   on conflict(id) do update set name=excluded.name,list_label=excluded.list_label,sort_order=excluded.sort_order,active=true,is_template=excluded.is_template;
   kept_c:=array_append(kept_c,cid); ord:=ord+1;
 end loop;
 -- Assigned stations must survive; a missing/foreign ID must not move people silently.
 for item in select value from jsonb_array_elements(p_stations) loop
   sid:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid());
   if sid=any(kept_s) or exists(select 1 from public.stations where id=sid and district_id<>p_district_id) then raise exception 'Identificador de local inválido o repetido.' using errcode='23514'; end if;
   kept_s:=array_append(kept_s,sid);
 end loop;
 if exists(select 1 from public.profiles p join public.stations st on st.id=p.station_id where st.district_id=p_district_id and not(st.id=any(kept_s))) then raise exception 'No puede quitar un local asignado a un puesto; reasigne antes.' using errcode='23514'; end if;
 update public.stations set active=false where district_id=p_district_id;
 ord:=1;
 for item in select value from jsonb_array_elements(p_stations) loop
   sid:=kept_s[ord]; nm:=btrim(coalesce(item->>'name',''));
   insert into public.stations(id,district_id,name,active,is_template,code,address,point_label,latitude,longitude)
     values(sid,p_district_id,nm,true,nm~*'(ejemplo|configurar|pendiente|práctica|NO OFICIAL)' or char_length(btrim(coalesce(item->>'address','')))<5,
       btrim(coalesce(item->>'code','')),btrim(coalesce(item->>'address','')),btrim(coalesce(item->>'point_label','')),
       nullif(item->>'latitude','')::double precision,nullif(item->>'longitude','')::double precision)
     on conflict(id) do update set name=excluded.name,active=true,is_template=excluded.is_template,code=excluded.code,address=excluded.address,point_label=excluded.point_label,latitude=excluded.latitude,longitude=excluded.longitude;
   ord:=ord+1;
 end loop;
 update public.settings set catalog_confirmed=false,updated_at=clock_timestamp() where id=1;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'catalog_saved',jsonb_build_object('district_id',p_district_id));
 update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id=p_district_id;
 end$$;


-- Export is admin-only; nothing is published by these functions.
create or replace function public.log_export(p_kind text) returns void language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 if p_kind not in ('district_aggregates','team_activity','station_aggregates','records') then raise exception 'Tipo inválido.' using errcode='23514';end if;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'export_requested',jsonb_build_object('kind',p_kind));
end$$;
do $$declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in
 ('submit_response_v2','get_dashboard_v2','get_records_v2','list_accounts_v2','set_viewer_access','set_operator_label') loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end$$;
commit;
