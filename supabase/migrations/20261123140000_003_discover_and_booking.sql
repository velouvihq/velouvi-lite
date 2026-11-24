begin;

create schema if not exists marketplace;
create schema if not exists api;
revoke all on schema marketplace, api from public, anon, authenticated;
grant usage on schema api to anon, authenticated, service_role;

create table marketplace.listings (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  slug text not null unique check (char_length(slug) between 2 and 80 and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  display_name text not null check (char_length(btrim(display_name)) between 2 and 120),
  description text not null default '' check (char_length(description) <= 1000),
  status text not null default 'draft' check (status in ('draft','published','unpublished')),
  moderated_by uuid references auth.users(id) on delete set null,
  moderated_at timestamptz,
  updated_at timestamptz not null default now(),
  foreign key (organization_id, location_id) references core.locations(organization_id,id),
  unique (organization_id, location_id)
);
alter table marketplace.listings enable row level security;
alter table marketplace.listings force row level security;
revoke all on marketplace.listings from public, anon, authenticated;
grant usage on schema marketplace to service_role;
grant select, insert, update on marketplace.listings to service_role;

create table ops.booking_request_details (
  organization_id uuid not null,
  booking_request_id uuid not null,
  location_id uuid not null,
  service_variant_id uuid not null,
  staff_profile_id uuid not null,
  label_snapshot text not null,
  duration_minutes integer not null check (duration_minutes between 1 and 1440),
  price_minor bigint not null check (price_minor >= 0),
  currency char(3) not null,
  tax_snapshot jsonb not null default '{}'::jsonb,
  primary key (organization_id, booking_request_id),
  foreign key (organization_id, booking_request_id, location_id)
    references ops.booking_requests(organization_id,id,location_id),
  foreign key (organization_id,location_id,service_variant_id)
    references commerce.service_locations(organization_id,location_id,service_variant_id),
  foreign key (organization_id,staff_profile_id,location_id)
    references core.staff_locations(organization_id,staff_profile_id,location_id)
);
alter table ops.booking_request_details enable row level security;
revoke all on ops.booking_request_details from public, anon, authenticated;
grant select, insert on ops.booking_request_details to service_role;

create table ops.booking_request_history (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  booking_request_id uuid not null,
  from_status text,
  to_status text not null check (to_status in ('submitted','accepted','declined','withdrawn','expired')),
  actor_user_id uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default now(),
  foreign key (organization_id, booking_request_id) references ops.booking_requests(organization_id,id)
);
alter table ops.booking_request_history enable row level security;
revoke all on ops.booking_request_history from public, anon, authenticated;
grant select on ops.booking_request_history to service_role;

-- Allocation and item must refer to the same appointment as well as the same branch.
alter table ops.appointment_items
  add constraint appointment_items_allocation_reference_unique unique(organization_id,id,location_id,appointment_id);
alter table ops.appointment_allocations add constraint appointment_allocations_item_appointment_fk
  foreign key(organization_id,appointment_item_id,location_id,appointment_id)
  references ops.appointment_items(organization_id,id,location_id,appointment_id);

create function private.booking_event(p_org uuid,p_type text,p_kind text,p_id uuid,p_data jsonb default '{}')
returns void language sql set search_path = '' as $$
  insert into ops.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values (p_org,p_type,p_kind,p_id,p_data);
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id,metadata)
  values (p_org,auth.uid(),p_type,'ops',p_kind,p_id,p_data);
$$;

-- All interactive workflows lock the organization before dependent rows.
create function private.lock_booking_org(p_org uuid)
returns void language plpgsql set search_path = '' as $$
begin
  perform 1 from core.organizations where id=p_org and status='active' for update;
  if not found then raise exception 'This organization is unavailable.' using errcode='P0002'; end if;
end;
$$;

create function private.expire_booking_holds(p_org uuid)
returns integer language plpgsql set search_path = '' as $$
declare a ops.appointments%rowtype;
declare changed integer := 0;
begin
  for a in
    update ops.appointments set status='expired'
    where organization_id=p_org and status='held' and held_until <= now()
    returning *
  loop
    update ops.appointment_allocations set is_blocking=false,released_at=now()
    where organization_id=p_org and appointment_id=a.id and is_blocking;
    insert into ops.appointment_status_history(organization_id,appointment_id,from_status,to_status,reason)
    values (p_org,a.id,'held','expired','Hold expired');
    perform private.booking_event(p_org,'appointment.expired','appointment',a.id);
    changed := changed + 1;
  end loop;
  return changed;
end;
$$;

create function api.expire_booking_holds()
returns integer language plpgsql security definer set search_path = '' as $$
declare oid uuid;
declare changed integer := 0;
begin
  for oid in select distinct a.organization_id from ops.appointments a
             where a.status='held' and a.held_until <= now() order by a.organization_id
  loop
    perform 1 from core.organizations where id=oid for update;
    changed := changed + private.expire_booking_holds(oid);
  end loop;
  return changed;
end;
$$;

create function private.booking_policy(p_org uuid,p_location uuid)
returns ops.booking_policy_versions language sql stable set search_path = '' as $$
  select v.* from ops.booking_policies p join ops.booking_policy_versions v
    on v.organization_id=p.organization_id and v.booking_policy_id=p.id
  where p.organization_id=p_org and p.is_active and (p.location_id=p_location or p.location_id is null)
    and v.effective_from <= now()
  order by (p.location_id is not null) desc,v.effective_from desc,v.version_number desc limit 1
$$;

-- Weekly hours use Sunday=0 and local wall time; check both possible start days for overnight shifts.
create function private.covers_booking_period(
  p_day date,p_dow integer,p_open time,p_close time,p_overnight boolean,p_zone text,p_period tstzrange
)
returns boolean language sql stable set search_path='' as $$
  select case when extract(dow from p_day)::integer = p_dow then
    ((p_day+p_open) at time zone p_zone) <= lower(p_period)
    and ((p_day+p_close+case when p_overnight then interval '1 day' else interval '0' end) at time zone p_zone)
      >= upper(p_period)
  else false end
$$;

create function private.booking_plan(
  p_org uuid,p_location uuid,p_variant uuid,p_start timestamptz,
  p_staff uuid default null,p_minutes integer default null,p_ignore_appointment uuid default null
)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  loc core.locations%rowtype;
  staff record;
  requirement record;
  slot tstzrange;
  local_day date;
  selected_resources uuid[];
  matched_resources uuid[];
  minutes integer;
  ends timestamptz;
  resources_ok boolean;
begin
  select * into loc from core.locations where organization_id=p_org and id=p_location and status='active';
  if not found or not isfinite(p_start) or p_start <= now() then return null; end if;
  if not exists(select from pg_catalog.pg_timezone_names where name=loc.timezone) then return null; end if;
  local_day := (p_start at time zone loc.timezone)::date;
  for staff in
    select sl.staff_profile_id, s.name as service_name, v.name as variant_name, v.currency, v.tax_code,
      coalesce(o.duration_minutes_override,l.duration_minutes_override,v.duration_minutes) as duration_minutes,
      coalesce(o.price_minor_override,l.price_minor_override,v.price_minor) as price_minor
    from commerce.service_locations l
    join commerce.service_variants v on (v.organization_id,v.id)=(l.organization_id,l.service_variant_id)
    join commerce.services s on (s.organization_id,s.id)=(v.organization_id,v.service_id)
    join core.staff_locations sl on (sl.organization_id,sl.location_id)=(l.organization_id,l.location_id)
    join core.staff_profiles sp on (sp.organization_id,sp.id)=(sl.organization_id,sl.staff_profile_id)
    left join commerce.staff_service_overrides o on (o.organization_id,o.location_id,o.service_variant_id,o.staff_profile_id)
      =(l.organization_id,l.location_id,l.service_variant_id,sl.staff_profile_id)
    where (l.organization_id,l.location_id,l.service_variant_id)=(p_org,p_location,p_variant)
      and l.is_enabled and v.is_active and s.is_active and sl.is_active and sp.is_active
      and coalesce(o.is_allowed,true) and (p_staff is null or sl.staff_profile_id=p_staff)
    order by sl.staff_profile_id
  loop
    minutes := coalesce(p_minutes,staff.duration_minutes);
    ends := p_start + make_interval(mins => minutes);
    slot := tstzrange(p_start,ends,'[)');
    if not exists (
      select from ops.location_hours h cross join (values (local_day),(local_day-1)) d(day)
      where (h.organization_id,h.location_id)=(p_org,p_location) and not h.is_closed
        and private.covers_booking_period(d.day,h.day_of_week,h.opens_at,h.closes_at,h.ends_next_day,loc.timezone,slot)
    ) or exists (
      select from ops.location_closures c where (c.organization_id,c.location_id)=(p_org,p_location)
        and tstzrange(c.starts_at,c.ends_at,'[)') && slot
    ) then continue; end if;

    if exists (
      select from ops.staff_exceptions e
      where (e.organization_id,e.location_id,e.staff_profile_id)=(p_org,p_location,staff.staff_profile_id)
        and e.exception_type='unavailable' and tstzrange(e.starts_at,e.ends_at,'[)') && slot
    ) or not (
      exists (
        select from ops.staff_availability a cross join (values (local_day),(local_day-1)) d(day)
        where (a.organization_id,a.location_id,a.staff_profile_id)=(p_org,p_location,staff.staff_profile_id)
          and d.day >= a.effective_from and (a.effective_to is null or d.day <= a.effective_to)
          and private.covers_booking_period(d.day,a.day_of_week,a.starts_at,a.ends_at,a.ends_next_day,loc.timezone,slot)
      ) or exists (
        select from ops.staff_exceptions e
        where (e.organization_id,e.location_id,e.staff_profile_id)=(p_org,p_location,staff.staff_profile_id)
          and e.exception_type='available' and tstzrange(e.starts_at,e.ends_at,'[)') @> slot
      )
    ) then continue; end if;

    if exists (
      select from ops.appointment_allocations a
      join ops.appointments ap on (ap.organization_id,ap.id)=(a.organization_id,a.appointment_id)
      where a.organization_id=p_org and a.allocation_kind='staff' and a.subject_id=staff.staff_profile_id
        and a.is_blocking and a.appointment_id is distinct from p_ignore_appointment
        and (ap.status <> 'held' or ap.held_until > now())
        and tstzrange(a.starts_at,a.ends_at,'[)') && slot
    ) then continue; end if;

    selected_resources := '{}'::uuid[];
    resources_ok := true;
    for requirement in
      select r.resource_type,r.quantity from ops.service_resource_requirements r
      where (r.organization_id,r.location_id,r.service_variant_id)=(p_org,p_location,p_variant)
      order by r.resource_type
    loop
      select array(select r.id from ops.resources r
        where (r.organization_id,r.location_id)=(p_org,p_location) and r.resource_type=requirement.resource_type
          and r.is_active and not exists (
            select from ops.appointment_allocations a
            join ops.appointments ap on (ap.organization_id,ap.id)=(a.organization_id,a.appointment_id)
            where a.organization_id=p_org and a.allocation_kind='resource' and a.subject_id=r.id
              and a.is_blocking and a.appointment_id is distinct from p_ignore_appointment
              and (ap.status <> 'held' or ap.held_until > now())
              and tstzrange(a.starts_at,a.ends_at,'[)') && slot
          ) order by r.id limit requirement.quantity) into matched_resources;
      if cardinality(matched_resources) <> requirement.quantity then resources_ok:=false; exit; end if;
      selected_resources := selected_resources || matched_resources;
    end loop;
    if resources_ok then
      return jsonb_build_object('staff_id',staff.staff_profile_id,'resources',selected_resources,
        'duration_minutes',minutes,'ends_at',ends,'price_minor',staff.price_minor,'currency',staff.currency,
        'tax',jsonb_build_object('code',staff.tax_code),
        'label',staff.service_name || ' · ' || staff.variant_name);
    end if;
  end loop;
  return null;
end;
$$;

create function private.allocate_booking(
  p_org uuid,p_location uuid,p_appointment uuid,p_item uuid,p_start timestamptz,p_plan jsonb
)
returns void language sql set search_path = '' as $$
  insert into ops.appointment_allocations(
    organization_id,location_id,appointment_id,appointment_item_id,allocation_kind,staff_profile_id,resource_id,starts_at,ends_at
  )
  select p_org,p_location,p_appointment,p_item,x.kind,x.staff_id,x.resource_id,p_start,(p_plan->>'ends_at')::timestamptz
  from (
    select 'staff'::text as kind,(p_plan->>'staff_id')::uuid as staff_id,null::uuid as resource_id
    union all
    select 'resource',null,value::uuid from pg_catalog.jsonb_array_elements_text(p_plan->'resources')
  ) x
$$;

create function api.discover_listings(p_slug text default null)
returns table(slug text,display_name text,description text,city text,timezone text)
language sql stable security definer set search_path='' as $$
  select m.slug,m.display_name,m.description,l.city,l.timezone
  from marketplace.listings m join core.locations l on (l.organization_id,l.id)=(m.organization_id,m.location_id)
  join core.organizations o on o.id=m.organization_id
  where m.status='published' and l.status='active' and o.status='active'
    and (p_slug is null or m.slug=p_slug)
  order by m.slug limit 100
$$;

create function api.discover_services(p_slug text)
returns table(variant_id uuid,service_name text,variant_name text,duration_minutes integer,price_minor bigint,currency text)
language sql stable security definer set search_path='' as $$
  select v.id,s.name,v.name,coalesce(sl.duration_minutes_override,v.duration_minutes),
      coalesce(sl.price_minor_override,v.price_minor),v.currency::text
  from marketplace.listings m
  join core.organizations o on o.id=m.organization_id and o.status='active'
  join core.locations l on (l.organization_id,l.id)=(m.organization_id,m.location_id) and l.status='active'
  join commerce.service_locations sl on (sl.organization_id,sl.location_id)=(m.organization_id,m.location_id)
  join commerce.service_variants v on (v.organization_id,v.id)=(sl.organization_id,sl.service_variant_id)
  join commerce.services s on (s.organization_id,s.id)=(v.organization_id,v.service_id)
  where m.slug=p_slug and m.status='published' and sl.is_enabled and v.is_active and s.is_active and v.booking_mode='request'
  order by s.name,v.name limit 200
$$;

create function api.save_listing(p_location uuid,p_slug text,p_name text,p_description text)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
declare result uuid;
begin
  select organization_id into org from core.locations where id=p_location;
  if auth.uid() is null or not coalesce(core.has_org_permission(org,'locations.manage',p_location),false) then
    raise exception 'Listing write access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(org);
  insert into marketplace.listings(organization_id,location_id,slug,display_name,description)
  values (org,p_location,p_slug,btrim(p_name),coalesce(btrim(p_description),''))
  on conflict (organization_id,location_id) do update
    set slug=excluded.slug,display_name=excluded.display_name,description=excluded.description,
        status='draft',updated_at=now(),moderated_at=null,moderated_by=null
  returning id into result;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values (org,auth.uid(),'listing.saved','marketplace','listings',result);
  return result;
end;
$$;

create function api.moderate_listing(p_listing uuid,p_publish boolean)
returns void language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
  if auth.uid() is null or not core.has_platform_permission('platform.moderation.manage') then
    raise exception 'Moderation access denied.' using errcode='42501';
  end if;
  if p_publish is null then raise exception 'Choose publish or unpublish.' using errcode='22023'; end if;
  select organization_id into org from marketplace.listings where id=p_listing;
  if org is null then raise exception 'Listing not found.' using errcode='P0002'; end if;
  perform 1 from core.organizations where id=org for update;
  update marketplace.listings set status=case when p_publish then 'published' else 'unpublished' end,
    updated_at=now(),moderated_at=now(),moderated_by=auth.uid()
  where id=p_listing;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values (org,auth.uid(),case when p_publish then 'listing.published' else 'listing.unpublished' end,
    'marketplace','listings',p_listing);
end;
$$;

create function api.booking_availability(p_slug text,p_variant uuid,p_start timestamptz)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare listing marketplace.listings%rowtype;
declare policy ops.booking_policy_versions%rowtype;
declare plan jsonb;
begin
  if p_start is null or not isfinite(p_start) then return jsonb_build_object('available',false); end if;
  if not exists(select from api.discover_services(p_slug) s where s.variant_id=p_variant) then
    return jsonb_build_object('available',false);
  end if;
  select * into listing from marketplace.listings where slug=p_slug and status='published';
  policy:=private.booking_policy(listing.organization_id,listing.location_id);
  if p_start < now()+make_interval(mins=>coalesce(policy.min_lead_minutes,0))
    or p_start > now()+make_interval(days=>coalesce(policy.max_advance_days,90))
    or coalesce(policy.deposit_required,false) then return jsonb_build_object('available',false); end if;
  plan:=private.booking_plan(listing.organization_id,listing.location_id,p_variant,p_start);
  if plan is null then return jsonb_build_object('available',false); end if;
  return jsonb_build_object('available',true,'ends_at',plan->'ends_at','price_minor',plan->'price_minor','currency',plan->'currency');
end;
$$;

create function api.submit_booking_request(
  p_slug text,p_variant uuid,p_start timestamptz,p_name text,p_email text,p_key uuid
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  listing marketplace.listings%rowtype;
  policy ops.booking_policy_versions%rowtype;
  previous ops.operation_requests%rowtype;
  h text;
  plan jsonb;
  result_id uuid;
  recipient uuid;
  guest_name text := btrim(coalesce(p_name,''));
  guest_email text := lower(btrim(coalesce(p_email,'')));
begin
  if p_key is null or p_start is null or not isfinite(p_start) or p_variant is null
     or char_length(guest_name) not between 2 and 160 or char_length(guest_email)>254
     or guest_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Enter a valid service, date, name and email.' using errcode='22023';
  end if;
  select * into listing from marketplace.listings where slug=p_slug and status='published';
  if not found then raise exception 'This listing is unavailable.' using errcode='P0002'; end if;
  perform private.lock_booking_org(listing.organization_id);
  if not exists(select from marketplace.listings m where m.id=listing.id and m.slug=p_slug and m.status='published') then
    raise exception 'This listing is unavailable.' using errcode='P0002';
  end if;
  h:=encode(extensions.digest(jsonb_build_array(listing.id,p_variant,extract(epoch from p_start),guest_name,guest_email)::text,'sha256'),'hex');
  select * into previous from ops.operation_requests
  where organization_id=listing.organization_id and operation_scope='discover_booking' and operation_key=p_key::text;
  if found then
    if previous.request_hash<>h then raise exception 'This request key was already used.' using errcode='22023'; end if;
    return (previous.result->>'request_id')::uuid;
  end if;

  if not exists(select from api.discover_services(p_slug) s where s.variant_id=p_variant) then
    raise exception 'This service is unavailable.' using errcode='P0002';
  end if;
  policy:=private.booking_policy(listing.organization_id,listing.location_id);
  if p_start < now()+make_interval(mins=>coalesce(policy.min_lead_minutes,0))
     or p_start > now()+make_interval(days=>coalesce(policy.max_advance_days,90))
     or coalesce(policy.deposit_required,false) then
    raise exception 'This time is outside the booking policy or requires a deposit.' using errcode='22023';
  end if;
  if 5 <= (select count(*) from ops.booking_requests r
    join ops.booking_request_participants p on (p.organization_id,p.booking_request_id)=(r.organization_id,r.id)
    join private.booking_participant_contacts c on (c.organization_id,c.participant_id)=(p.organization_id,p.id)
    where r.organization_id=listing.organization_id and r.submitted_at >= now()-interval '1 hour'
      and p.participant_role='requester' and c.email=guest_email) then
    raise exception 'Too many booking requests for this email. Try again later.' using errcode='22023';
  end if;
  plan:=private.booking_plan(listing.organization_id,listing.location_id,p_variant,p_start);
  if plan is null then raise exception 'This time is unavailable.' using errcode='23P01'; end if;

  insert into ops.booking_requests(organization_id,location_id,requested_start_at,requested_end_at,source,policy_version_id,request_key)
  values (listing.organization_id,listing.location_id,p_start,(plan->>'ends_at')::timestamptz,'discover',policy.id,p_key::text)
  returning id into result_id;
  insert into ops.booking_request_details(organization_id,booking_request_id,location_id,service_variant_id,
    staff_profile_id,label_snapshot,duration_minutes,price_minor,currency,tax_snapshot)
  values (listing.organization_id,result_id,listing.location_id,p_variant,(plan->>'staff_id')::uuid,plan->>'label',
    (plan->>'duration_minutes')::integer,(plan->>'price_minor')::bigint,plan->>'currency',plan->'tax');
  insert into ops.booking_request_participants(organization_id,booking_request_id,participant_role)
  values (listing.organization_id,result_id,'requester') returning id into recipient;
  insert into private.booking_participant_contacts(organization_id,participant_id,display_name,email)
  values (listing.organization_id,recipient,guest_name,guest_email);
  insert into ops.booking_request_history(organization_id,booking_request_id,to_status)
  values (listing.organization_id,result_id,'submitted');
  insert into ops.operation_requests(organization_id,operation_scope,operation_key,request_hash,status,result,completed_at)
  values (listing.organization_id,'discover_booking',p_key::text,h,'completed',jsonb_build_object('request_id',result_id),now());
  perform private.booking_event(listing.organization_id,'booking.submitted','booking_request',result_id);
  return result_id;
end;
$$;

create function api.booking_locations()
returns table(id uuid,organization_id uuid,name text,timezone text,listing_slug text,listing_status text)
language sql stable security definer set search_path='' as $$
  select l.id,l.organization_id,l.name,l.timezone,m.slug,m.status
  from core.locations l join core.organizations o on o.id=l.organization_id and o.status='active'
  left join marketplace.listings m on (m.organization_id,m.location_id)=(l.organization_id,l.id)
  where l.status='active' and core.has_org_permission(l.organization_id,'appointments.read',l.id)
  order by l.name limit 100
$$;

create function api.booking_inbox(p_location uuid)
returns table(id uuid,starts_at timestamptz,ends_at timestamptz,service text,guest_name text,guest_email text)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from core.locations where core.locations.id=p_location;
  if not coalesce(core.has_org_permission(org,'booking_requests.read',p_location),false) then
    raise exception 'Booking inbox access denied.' using errcode='42501';
  end if;
  return query
  select r.id,r.requested_start_at,r.requested_end_at,d.label_snapshot,c.display_name,c.email
  from ops.booking_requests r
  join ops.booking_request_details d on (d.organization_id,d.booking_request_id)=(r.organization_id,r.id)
  left join lateral (
    select c.display_name,c.email from ops.booking_request_participants p
    join private.booking_participant_contacts c on (c.organization_id,c.participant_id)=(p.organization_id,p.id)
    where (p.organization_id,p.booking_request_id)=(r.organization_id,r.id) and p.participant_role='requester'
    order by p.created_at,p.id,c.created_at,c.id limit 1
  ) c on true
  where r.organization_id=org and r.location_id=p_location and r.status='submitted'
    and (r.expires_at is null or r.expires_at>now())
  order by r.submitted_at,r.id limit 200;
end;
$$;

create function api.booking_calendar(p_location uuid,p_from timestamptz,p_to timestamptz)
returns table(id uuid,starts_at timestamptz,ends_at timestamptz,status text,service text)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from core.locations where core.locations.id=p_location;
  if not coalesce(core.has_org_permission(org,'appointments.read',p_location),false) then
    raise exception 'Calendar access denied.' using errcode='42501';
  end if;
  if p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to)
    or p_to<=p_from or p_to>p_from+interval '93 days' then
    raise exception 'Choose a calendar range of up to 93 days.' using errcode='22023';
  end if;
  return query
  select a.id,a.starts_at,a.ends_at,a.status,(
    select string_agg(i.item_name_snapshot,', ' order by i.sort_order,i.id)
    from ops.appointment_items i where (i.organization_id,i.appointment_id)=(a.organization_id,a.id)
  )
  from ops.appointments a
  where a.organization_id=org and a.location_id=p_location and a.starts_at<p_to and a.ends_at>p_from
    and a.status not in ('cancelled','expired')
    and (a.status<>'held' or a.held_until>now())
  order by a.starts_at,a.id limit 500;
end;
$$;

create function api.decide_booking_request(p_request uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  req ops.booking_requests%rowtype;
  item ops.booking_request_details%rowtype;
  plan jsonb;
  client uuid;
  appointment uuid;
  item_id uuid;
  attendee uuid;
  guest record;
  outcome text;
begin
  if p_accept is null then raise exception 'Choose accept or decline.' using errcode='22023'; end if;
  select * into req from ops.booking_requests where id=p_request;
  if auth.uid() is null or not coalesce(core.has_org_permission(req.organization_id,'appointments.manage',req.location_id),false) then
    raise exception 'Booking management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(req.organization_id);
  if not core.has_org_permission(req.organization_id,'appointments.manage',req.location_id) then
    raise exception 'Booking management access denied.' using errcode='42501';
  end if;
  select * into req from ops.booking_requests where id=p_request for update;
  outcome:=case when p_accept then 'accepted' else 'declined' end;
  if req.status=outcome then
    select id into appointment from ops.appointments where organization_id=req.organization_id and booking_request_id=req.id;
    return jsonb_build_object('status',outcome,'appointment_id',appointment);
  end if;
  if req.status<>'submitted' or (req.expires_at is not null and req.expires_at<=now()) then
    raise exception 'The request is no longer open.' using errcode='22023';
  end if;

  if p_accept then
    select * into item from ops.booking_request_details
    where (organization_id,booking_request_id)=(req.organization_id,req.id);
    if not found then raise exception 'This request is missing its service snapshot.' using errcode='22023'; end if;
    perform private.expire_booking_holds(req.organization_id);
    plan:=private.booking_plan(req.organization_id,req.location_id,item.service_variant_id,req.requested_start_at,
      item.staff_profile_id,item.duration_minutes);
    if plan is null then raise exception 'The assigned staff or resources are unavailable.' using errcode='23P01'; end if;
    select c.display_name,c.email into guest from ops.booking_request_participants p
    join private.booking_participant_contacts c on (c.organization_id,c.participant_id)=(p.organization_id,p.id)
    where (p.organization_id,p.booking_request_id)=(req.organization_id,req.id) and p.participant_role='requester'
    order by p.created_at,p.id,c.created_at,c.id limit 1;
    client:=req.client_id;
    if client is null and guest.display_name is not null then
      insert into core.clients(organization_id,display_name)
      values (req.organization_id,guest.display_name) returning id into client;
      insert into private.client_contacts(organization_id,client_id,contact_type,normalized_value,display_value,is_primary)
      values (req.organization_id,client,'email',guest.email,guest.email,true);
    end if;
    insert into ops.appointments(organization_id,location_id,booking_request_id,primary_client_id,
      starts_at,ends_at,status,source,confirmed_at,created_by_user_id)
    values (req.organization_id,req.location_id,req.id,client,
      req.requested_start_at,(plan->>'ends_at')::timestamptz,'confirmed',req.source,now(),auth.uid())
    returning id into appointment;
    insert into ops.appointment_items(organization_id,appointment_id,location_id,service_variant_id,
      item_name_snapshot,duration_minutes,price_minor,currency,tax_snapshot,starts_at,ends_at)
    values (req.organization_id,appointment,req.location_id,item.service_variant_id,
      item.label_snapshot,item.duration_minutes,item.price_minor,item.currency,item.tax_snapshot,
      req.requested_start_at,(plan->>'ends_at')::timestamptz) returning id into item_id;
    perform private.allocate_booking(req.organization_id,req.location_id,appointment,item_id,req.requested_start_at,plan);
    if guest.display_name is not null then
      insert into ops.appointment_participants(organization_id,appointment_id,client_id,participant_role)
      values (req.organization_id,appointment,client,'requester') returning id into attendee;
      insert into private.appointment_participant_contacts(organization_id,participant_id,display_name,email)
      values (req.organization_id,attendee,guest.display_name,guest.email);
    end if;
    insert into ops.appointment_status_history(organization_id,appointment_id,to_status,actor_user_id)
    values (req.organization_id,appointment,'confirmed',auth.uid());
    perform private.booking_event(req.organization_id,'appointment.confirmed','appointment',appointment);
  end if;
  update ops.booking_requests set status=outcome,decided_at=now(),decided_by_user_id=auth.uid()
  where id=req.id;
  insert into ops.booking_request_history(organization_id,booking_request_id,from_status,to_status,actor_user_id)
  values (req.organization_id,req.id,'submitted',outcome,auth.uid());
  perform private.booking_event(req.organization_id,'booking.'||outcome,'booking_request',req.id);
  return jsonb_build_object('status',outcome,'appointment_id',appointment);
end;
$$;

create function api.reschedule_appointment(p_appointment uuid,p_start timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a ops.appointments%rowtype;
  item ops.appointment_items%rowtype;
  staff uuid;
  plan jsonb;
  new_end timestamptz;
  delta interval;
begin
  select * into a from ops.appointments where id=p_appointment;
  if not coalesce(core.has_org_permission(a.organization_id,'appointments.manage',a.location_id),false) then
    raise exception 'Appointment management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(a.organization_id);
  if not core.has_org_permission(a.organization_id,'appointments.manage',a.location_id) then
    raise exception 'Appointment management access denied.' using errcode='42501';
  end if;
  select * into a from ops.appointments where id=p_appointment for update;
  if a.status<>'confirmed' or a.starts_at<=now() or p_start is null or not isfinite(p_start) or p_start<=now() then
    raise exception 'Only future confirmed appointments can be moved to a future time.' using errcode='22023';
  end if;
  if a.starts_at=p_start then return jsonb_build_object('id',a.id,'starts_at',a.starts_at,'ends_at',a.ends_at); end if;
  select * into item from ops.appointment_items where (organization_id,appointment_id)=(a.organization_id,a.id)
  order by sort_order,id limit 1;
  if item.service_variant_id is null or exists (
    select from ops.appointment_items i where (i.organization_id,i.appointment_id)=(a.organization_id,a.id) and i.id<>item.id
  ) then raise exception 'This appointment requires a manual multi-service reschedule.' using errcode='22023'; end if;
  select staff_profile_id into staff from ops.appointment_allocations
  where (organization_id,appointment_id)=(a.organization_id,a.id) and allocation_kind='staff' and is_blocking
  order by starts_at,id limit 1;
  perform private.expire_booking_holds(a.organization_id);
  plan:=private.booking_plan(a.organization_id,a.location_id,item.service_variant_id,p_start,staff,item.duration_minutes,a.id);
  if plan is null then raise exception 'The new time is unavailable.' using errcode='23P01'; end if;
  new_end:=(plan->>'ends_at')::timestamptz;
  delta:=p_start-a.starts_at;
  update ops.appointment_allocations set is_blocking=false,released_at=now()
  where organization_id=a.organization_id and appointment_id=a.id and is_blocking;
  perform private.allocate_booking(a.organization_id,a.location_id,a.id,item.id,p_start,plan);
  update ops.appointment_item_add_ons set starts_at=starts_at+delta,ends_at=ends_at+delta
  where organization_id=a.organization_id and appointment_item_id=item.id;
  update ops.appointment_items set starts_at=p_start,ends_at=new_end where id=item.id;
  update ops.appointments set starts_at=p_start,ends_at=new_end where id=a.id;
  insert into ops.appointment_status_history(organization_id,appointment_id,from_status,to_status,actor_user_id,reason,metadata)
  values (a.organization_id,a.id,'confirmed','confirmed',auth.uid(),'Rescheduled',
    jsonb_build_object('previous_start',a.starts_at,'new_start',p_start));
  perform private.booking_event(a.organization_id,'appointment.rescheduled','appointment',a.id,
    jsonb_build_object('previous_start',a.starts_at,'new_start',p_start));
  return jsonb_build_object('id',a.id,'starts_at',p_start,'ends_at',new_end);
end;
$$;

create function api.cancel_appointment(p_appointment uuid)
returns text language plpgsql security definer set search_path='' as $$
declare a ops.appointments%rowtype;
begin
  select * into a from ops.appointments where id=p_appointment;
  if not coalesce(core.has_org_permission(a.organization_id,'appointments.manage',a.location_id),false) then
    raise exception 'Appointment management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(a.organization_id);
  if not core.has_org_permission(a.organization_id,'appointments.manage',a.location_id) then
    raise exception 'Appointment management access denied.' using errcode='42501';
  end if;
  select * into a from ops.appointments where id=p_appointment for update;
  if a.status='cancelled' then return 'cancelled'; end if;
  if a.status not in ('held','confirmed') then
    raise exception 'This appointment cannot be cancelled.' using errcode='22023';
  end if;
  update ops.appointment_allocations set is_blocking=false,released_at=now()
  where organization_id=a.organization_id and appointment_id=a.id and is_blocking;
  update ops.appointments set status='cancelled',cancelled_at=now() where id=a.id;
  insert into ops.appointment_status_history(organization_id,appointment_id,from_status,to_status,actor_user_id)
  values (a.organization_id,a.id,a.status,'cancelled',auth.uid());
  perform private.booking_event(a.organization_id,'appointment.cancelled','appointment',a.id);
  return 'cancelled';
end;
$$;

revoke all on all functions in schema api from public, anon, authenticated, service_role;
revoke all on function private.booking_event(uuid,text,text,uuid,jsonb),private.lock_booking_org(uuid),
  private.expire_booking_holds(uuid),private.booking_policy(uuid,uuid),
  private.covers_booking_period(date,integer,time,time,boolean,text,tstzrange),
  private.booking_plan(uuid,uuid,uuid,timestamptz,uuid,integer,uuid),
  private.allocate_booking(uuid,uuid,uuid,uuid,timestamptz,jsonb)
  from public, anon, authenticated;
grant execute on function api.discover_listings(text),api.discover_services(text),
  api.booking_availability(text,uuid,timestamptz),api.submit_booking_request(text,uuid,timestamptz,text,text,uuid)
  to anon, authenticated;
grant execute on function api.save_listing(uuid,text,text,text),api.moderate_listing(uuid,boolean),api.booking_locations(),
  api.booking_inbox(uuid),api.booking_calendar(uuid,timestamptz,timestamptz),api.decide_booking_request(uuid,boolean),
  api.reschedule_appointment(uuid,timestamptz),api.cancel_appointment(uuid) to authenticated;
grant execute on function api.expire_booking_holds() to service_role;

notify pgrst, 'reload schema';
commit;
