begin;

alter table ops.outbox_events add column lease_key uuid;
alter table ops.outbox_events add column provider_message_id text;

create function api.claim_booking_notifications(p_limit integer default 10)
returns table(event_id uuid,lease uuid,kind text,recipient_email text,reference text,starts_at timestamptz,timezone text,studio text)
language plpgsql security definer set search_path='' as $$
begin
  if p_limit not between 1 and 20 or p_limit is null then
    raise exception 'Use a batch size between 1 and 20.' using errcode='22023';
  end if;

  -- A worker may have sent the email before losing its connection. A stale lease needs review.
  update ops.outbox_events e set status='failed',last_error_code='delivery_unknown',lease_key=null,locked_at=null
  where e.status='processing' and e.locked_at<now()-interval '15 minutes' and e.lease_key is not null;

  return query
  with candidate as (
    select e.id from ops.outbox_events e
    where e.event_type in ('booking.declined','appointment.confirmed','appointment.rescheduled','appointment.cancelled')
      and (e.status='pending' or (e.status='failed' and e.last_error_code='provider_rate_limited'))
      and e.available_at<=now() and e.attempts<5
    order by e.available_at,e.created_at,e.id limit p_limit for update skip locked
  ), claimed as (
    update ops.outbox_events e set status='processing',locked_at=now(),lease_key=extensions.gen_random_uuid(),
      attempts=e.attempts+1
    from candidate c where c.id=e.id
    returning e.*
  )
  select e.id,e.lease_key,e.event_type,coalesce(ac.email,bc.email),e.aggregate_id::text,
    coalesce(a.starts_at,b.requested_start_at),l.timezone,o.name
  from claimed e
  join core.organizations o on o.id=e.organization_id
  left join ops.appointments a on e.aggregate_type='appointment' and (a.organization_id,a.id)=(e.organization_id,e.aggregate_id)
  left join ops.booking_requests b on e.aggregate_type='booking_request' and (b.organization_id,b.id)=(e.organization_id,e.aggregate_id)
  left join core.locations l on (l.organization_id,l.id)=(e.organization_id,coalesce(a.location_id,b.location_id))
  left join lateral (
    select c.email from ops.appointment_participants p join private.appointment_participant_contacts c
      on (c.organization_id,c.participant_id)=(p.organization_id,p.id)
    where (p.organization_id,p.appointment_id)=(e.organization_id,a.id) and p.participant_role='requester'
      and ((e.event_type='appointment.cancelled' and a.status='cancelled')
        or (e.event_type in ('appointment.confirmed','appointment.rescheduled') and a.status='confirmed'))
      and (e.event_type<>'appointment.rescheduled' or (e.payload->>'new_start')::timestamptz=a.starts_at)
    order by p.created_at,p.id,c.created_at,c.id limit 1
  ) ac on true
  left join lateral (
    select c.email from ops.booking_request_participants p join private.booking_participant_contacts c
      on (c.organization_id,c.participant_id)=(p.organization_id,p.id)
    where (p.organization_id,p.booking_request_id)=(e.organization_id,b.id)
      and p.participant_role='requester' and b.status='declined'
    order by p.created_at,p.id,c.created_at,c.id limit 1
  ) bc on true;
end;
$$;

create function api.finish_booking_notification(p_event uuid,p_lease uuid,p_outcome text,p_provider_id text default null)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_outcome is null or p_outcome not in ('sent','skipped','provider_rate_limited','provider_rejected','delivery_unknown')
    or char_length(p_provider_id)>255 then
    raise exception 'Invalid notification result.' using errcode='22023';
  end if;
  update ops.outbox_events e set
    status=case when p_outcome in ('sent','skipped') then 'processed' else 'failed' end,
    processed_at=case when p_outcome in ('sent','skipped') then now() end,
    provider_message_id=case when p_outcome='sent' then p_provider_id end,
    available_at=case when p_outcome='provider_rate_limited' then now()+make_interval(mins=>e.attempts*5) else e.available_at end,
    last_error_code=case when p_outcome='sent' then null else p_outcome end,
    lease_key=null,locked_at=null
  where id=p_event and lease_key=p_lease and status='processing';
  return found;
end;
$$;

revoke all on function api.claim_booking_notifications(integer),api.finish_booking_notification(uuid,uuid,text,text)
  from public,anon,authenticated,service_role;
grant execute on function api.claim_booking_notifications(integer),api.finish_booking_notification(uuid,uuid,text,text)
  to service_role;
notify pgrst, 'reload schema';
commit;
