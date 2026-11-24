begin;

create schema if not exists billing;
revoke all on schema billing from public,anon,authenticated;
grant usage on schema billing to service_role;

create table billing.plans (
  code text primary key,
  name text not null,
  currency char(3) not null default 'LKR',
  monthly_price_minor bigint,
  constraint plans_price_check check (monthly_price_minor is null or monthly_price_minor>=0)
);
insert into billing.plans(code,name,monthly_price_minor)
values ('free','Free booking inbox',0),('lite','Velouvi Lite',null);

create table billing.plan_features (
  plan_code text references billing.plans(code),
  feature_code text not null,
  primary key(plan_code,feature_code)
);
insert into billing.plan_features values
  ('free','booking_inbox'),('free','calendar'),('free','marketplace_listing'),
  ('lite','booking_inbox'),('lite','calendar'),('lite','marketplace_listing'),('lite','lite_workspace');

create table billing.subscriptions (
  organization_id uuid primary key references core.organizations(id),
  plan_code text not null references billing.plans(code),
  status text not null check (status in ('trialing','active','cancelled')),
  period_start timestamptz not null,
  period_end timestamptz,
  trial_started_at timestamptz,
  updated_at timestamptz not null default now(),
  check (period_end is null or period_end>period_start),
  check (status<>'trialing' or (period_end is not null and trial_started_at is not null))
);

alter table billing.plans enable row level security;
alter table billing.plan_features enable row level security;
alter table billing.subscriptions enable row level security;
revoke all on all tables in schema billing from public,anon,authenticated;
grant select on all tables in schema billing to service_role;

create function private.current_booking_plan(p_org uuid)
returns text language sql stable set search_path='' as $$
  select coalesce((select s.plan_code from billing.subscriptions s
    where s.organization_id=p_org and s.status in ('trialing','active') and s.period_start<=now()
      and (s.period_end is null or s.period_end>now())), 'free')
$$;

create function api.booking_plan_status(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare plan text;
declare s billing.subscriptions%rowtype;
begin
  if not core.has_org_permission(p_org,'billing.read') then
    raise exception 'Billing access denied.' using errcode='42501';
  end if;
  plan:=private.current_booking_plan(p_org);
  select * into s from billing.subscriptions where organization_id=p_org;
  return jsonb_build_object('plan',plan,'trial_ends_at',case when s.status='trialing' then s.period_end end,
    'trial_used',s.trial_started_at is not null,
    'features',(select jsonb_agg(feature_code order by feature_code) from billing.plan_features where plan_code=plan));
end;
$$;

create function api.start_lite_trial(p_org uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not core.has_org_permission(p_org,'billing.manage') then
    raise exception 'Billing access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(p_org);
  if not core.has_org_permission(p_org,'billing.manage') then
    raise exception 'Billing access denied.' using errcode='42501';
  end if;
  if exists (select from billing.subscriptions where organization_id=p_org and trial_started_at is not null)
     or private.current_booking_plan(p_org)='lite' then
    return api.booking_plan_status(p_org);
  end if;
  insert into billing.subscriptions(organization_id,plan_code,status,period_start,period_end,trial_started_at)
  values (p_org,'lite','trialing',now(),now()+interval '7 days',now())
  on conflict (organization_id) do update set plan_code='lite',status='trialing',period_start=excluded.period_start,
    period_end=excluded.period_end,trial_started_at=excluded.trial_started_at,updated_at=now();
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table)
  values (p_org,auth.uid(),'trial.started','billing','subscriptions');
  return api.booking_plan_status(p_org);
end;
$$;

create function api.set_lite_subscription(p_org uuid,p_active boolean,p_until timestamptz default null)
returns void language plpgsql security definer set search_path='' as $$
begin
  if p_active is null or (p_until is not null and (not isfinite(p_until) or p_until<=now())) then
    raise exception 'The subscription end date must be in the future.' using errcode='22023';
  end if;
  perform private.lock_booking_org(p_org);
  insert into billing.subscriptions(organization_id,plan_code,status,period_start,period_end)
  values (p_org,'lite',case when p_active then 'active' else 'cancelled' end,now(),p_until)
  on conflict (organization_id) do update set status=excluded.status,period_start=excluded.period_start,
    period_end=excluded.period_end,updated_at=now();
  insert into private.audit_events(organization_id,action,entity_schema,entity_table,metadata)
  values (p_org,'subscription.updated','billing','subscriptions',jsonb_build_object('active',p_active,'until',p_until));
end;
$$;

create function api.create_booking_business(p_name text,p_slug text,p_branch text,p_timezone text default 'Asia/Colombo')
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
declare org uuid;
declare member uuid;
declare loc uuid;
begin
  if uid is null or not exists(select from auth.users where id=uid and email_confirmed_at is not null) then
    raise exception 'A verified account is required.' using errcode='42501';
  end if;
  if char_length(btrim(p_name)) not between 2 and 120 or char_length(btrim(p_branch)) not between 2 and 120
    or char_length(p_slug) not between 2 and 80 or p_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    or not exists(select from pg_catalog.pg_timezone_names where name=p_timezone) then
    raise exception 'Enter a valid business name, slug, branch and timezone.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text,1414));
  if (select count(*) from core.organizations where created_by=uid) >= 10 then
    raise exception 'This account has reached its business setup limit.' using errcode='22023';
  end if;
  insert into core.organizations(name,slug,timezone,created_by)
  values (btrim(p_name),p_slug,p_timezone,uid) returning id into org;
  insert into core.locations(organization_id,name,timezone,is_default)
  values (org,btrim(p_branch),p_timezone,true) returning id into loc;
  insert into core.memberships(organization_id,user_id,status,activated_at)
  values (org,uid,'active',now()) returning id into member;
  insert into core.role_assignments(organization_id,membership_id,role_id)
  select org,member,id from core.roles where code='owner';
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values (org,uid,'organization.created','core','organizations',org);
  return jsonb_build_object('organization_id',org,'location_id',loc);
end;
$$;

create function api.add_booking_branch(p_org uuid,p_name text,p_timezone text default 'Asia/Colombo')
returns uuid language plpgsql security definer set search_path='' as $$
declare loc uuid;
begin
  if not core.has_org_permission(p_org,'locations.manage') then
    raise exception 'Branch management access denied.' using errcode='42501';
  end if;
  if char_length(btrim(p_name)) not between 2 and 120
    or not exists(select from pg_catalog.pg_timezone_names where name=p_timezone) then
    raise exception 'Enter a valid branch name and timezone.' using errcode='22023';
  end if;
  perform private.lock_booking_org(p_org);
  if not core.has_org_permission(p_org,'locations.manage') then
    raise exception 'Branch management access denied.' using errcode='42501';
  end if;
  insert into core.locations(organization_id,name,timezone)
  values (p_org,btrim(p_name),p_timezone) returning id into loc;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values(p_org,auth.uid(),'location.created','core','locations',loc);
  return loc;
end;
$$;

-- Minimal branch setup. Additional shifts/closures and staff linking use separate workflows.
create function api.add_bookable_service(p_location uuid,p_name text,p_duration integer,p_price_minor bigint)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
declare service uuid;
declare variant uuid;
begin
  select organization_id into org from core.locations where id=p_location and status='active';
  if not core.has_org_permission(org,'services.manage',p_location) then
    raise exception 'Service management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(org);
  if not core.has_org_permission(org,'services.manage',p_location) then
    raise exception 'Service management access denied.' using errcode='42501';
  end if;
  if char_length(btrim(p_name)) not between 2 and 160 or p_duration not between 1 and 1440
    or p_price_minor<0 then
    raise exception 'Use a valid name, duration and price.' using errcode='22023';
  end if;
  insert into commerce.services(organization_id,name) values (org,btrim(p_name)) returning id into service;
  insert into commerce.service_variants(organization_id,service_id,name,duration_minutes,price_minor)
  values (org,service,'Standard',p_duration,p_price_minor) returning id into variant;
  insert into commerce.service_locations(organization_id,location_id,service_variant_id)
  values (org,p_location,variant);
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values (org,auth.uid(),'service.created','commerce','services',service);
  return variant;
end;
$$;

create function api.add_booking_staff(p_location uuid,p_name text)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
declare staff uuid;
begin
  select organization_id into org from core.locations where id=p_location and status='active';
  if not core.has_org_permission(org,'schedule.manage',p_location) then
    raise exception 'Staff management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(org);
  if not core.has_org_permission(org,'schedule.manage',p_location) then
    raise exception 'Staff management access denied.' using errcode='42501';
  end if;
  insert into core.staff_profiles(organization_id,display_name)
  values(org,btrim(p_name)) returning id into staff;
  insert into core.staff_locations(organization_id,staff_profile_id,location_id,is_primary)
  values(org,staff,p_location,true);
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values(org,auth.uid(),'staff.created','core','staff_profiles',staff);
  return staff;
end;
$$;

create function api.set_booking_week(p_location uuid,p_days smallint[],p_open time,p_close time)
returns void language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from core.locations where id=p_location and status='active';
  if not core.has_org_permission(org,'schedule.manage',p_location) then
    raise exception 'Schedule management access denied.' using errcode='42501';
  end if;
  if p_days is null or cardinality(p_days) not between 1 and 7 or exists(
    select from unnest(p_days) d(day) where d.day is null or d.day not between 0 and 6
  ) or p_open is null or p_close is null or p_open>=p_close then
    raise exception 'Choose valid open days and opening hours.' using errcode='22023';
  end if;
  perform private.lock_booking_org(org);
  if not core.has_org_permission(org,'schedule.manage',p_location) then
    raise exception 'Schedule management access denied.' using errcode='42501';
  end if;
  if exists(select from ops.appointments
    where organization_id=org and location_id=p_location and starts_at>now()
      and status in ('held','confirmed','checked_in','in_service')) then
    raise exception 'Existing appointments require a managed schedule change.' using errcode='22023';
  end if;
  delete from ops.location_hours where organization_id=org and location_id=p_location;
  delete from ops.staff_availability where organization_id=org and location_id=p_location;
  insert into ops.location_hours (organization_id,location_id,day_of_week,opens_at,closes_at)
  select distinct org,p_location,d.day,p_open,p_close from unnest(p_days) d(day);
  insert into ops.staff_availability (organization_id,location_id,staff_profile_id,day_of_week,starts_at,ends_at)
  select distinct org,p_location,sl.staff_profile_id,d.day,p_open,p_close
  from core.staff_locations sl cross join unnest(p_days) d(day)
  where sl.organization_id=org and sl.location_id=p_location and sl.is_active;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values (org,auth.uid(),'schedule.week_set','core','locations',p_location);
end;
$$;

revoke all on function private.current_booking_plan(uuid) from public,anon,authenticated;
revoke all on function api.booking_plan_status(uuid),api.start_lite_trial(uuid),
  api.create_booking_business(text,text,text,text),api.add_booking_branch(uuid,text,text),
  api.add_bookable_service(uuid,text,integer,bigint),api.add_booking_staff(uuid,text),
  api.set_booking_week(uuid,smallint[],time,time),api.set_lite_subscription(uuid,boolean,timestamptz)
  from public,anon,authenticated,service_role;
grant execute on function api.booking_plan_status(uuid),api.start_lite_trial(uuid),
  api.create_booking_business(text,text,text,text),api.add_booking_branch(uuid,text,text),
  api.add_bookable_service(uuid,text,integer,bigint),api.add_booking_staff(uuid,text),
  api.set_booking_week(uuid,smallint[],time,time) to authenticated;
grant execute on function api.set_lite_subscription(uuid,boolean,timestamptz) to service_role;

create function api.booking_listing_draft(p_location uuid)
returns table(id uuid,slug text,display_name text,description text,status text)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from core.locations where core.locations.id=p_location;
  if not core.has_org_permission(org,'locations.manage',p_location) then
    raise exception 'Listing access denied.' using errcode='42501';
  end if;
  return query select m.id,m.slug,m.display_name,m.description,m.status
    from marketplace.listings m where m.organization_id=org and m.location_id=p_location;
end;
$$;

create function api.listing_review_queue()
returns table(id uuid,slug text,display_name text,description text,status text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not core.has_platform_permission('platform.moderation.manage') then
    raise exception 'Moderation access denied.' using errcode='42501';
  end if;
  return query select m.id,m.slug,m.display_name,m.description,m.status
    from marketplace.listings m join core.organizations o on o.id=m.organization_id and o.status='active'
    order by (m.status='draft') desc,m.updated_at desc,m.id limit 100;
end;
$$;

revoke all on function api.booking_listing_draft(uuid),api.listing_review_queue() from public,anon,authenticated,service_role;
grant execute on function api.booking_listing_draft(uuid),api.listing_review_queue() to authenticated;

notify pgrst, 'reload schema';
commit;
