begin;

create table billing.sandbox_payment_orders (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  appointment_id uuid not null,
  amount_minor bigint not null check (amount_minor>0),
  currency text not null check (currency='LKR'),
  status text not null default 'created' check (status in ('created','pending','paid','cancelled','failed','chargeback')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(organization_id,appointment_id) references ops.appointments(organization_id,id),
  unique(organization_id,appointment_id)
);

create table billing.sandbox_payment_events (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references billing.sandbox_payment_orders(id),
  provider_status text not null check(provider_status in ('2','0','-1','-2','-3')),
  provider_reference text,
  disposition text not null check (disposition in ('applied','ignored','amount_mismatch')),
  created_at timestamptz not null default now(),
  unique(order_id,provider_status,disposition)
);

alter table billing.sandbox_payment_orders enable row level security;
alter table billing.sandbox_payment_events enable row level security;
revoke all on billing.sandbox_payment_orders,billing.sandbox_payment_events from public,anon,authenticated;
grant select on billing.sandbox_payment_orders,billing.sandbox_payment_events to service_role;

create function api.prepare_payhere_sandbox_order(p_appointment uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a ops.appointments%rowtype;
declare payment billing.sandbox_payment_orders%rowtype;
declare total bigint;
begin
  select * into a from ops.appointments where id=p_appointment;
  if not (core.has_org_permission(a.organization_id,'appointments.manage',a.location_id)
      and core.has_org_permission(a.organization_id,'billing.manage')) then
    raise exception 'Sandbox payment access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(a.organization_id);
  if not core.has_org_permission(a.organization_id,'billing.manage') then
    raise exception 'Sandbox payment access denied.' using errcode='42501';
  end if;
  select * into a from ops.appointments where id=p_appointment for update;
  if a.status<>'confirmed' then raise exception 'A confirmed booking is required.' using errcode='22023'; end if;
  select * into payment from billing.sandbox_payment_orders
  where (organization_id,appointment_id)=(a.organization_id,a.id);
  if not found then
    if exists(select from ops.appointment_items i where (i.organization_id,i.appointment_id)=(a.organization_id,a.id)
      and i.currency<>'LKR') then
      raise exception 'Sandbox supports LKR orders only.' using errcode='22023';
    end if;
    select coalesce(sum(i.price_minor),0) into total from ops.appointment_items i
    where (i.organization_id,i.appointment_id)=(a.organization_id,a.id);
    if total<=0 or total>99999999900 then
      raise exception 'Choose an appointment inside the sandbox order amount range.' using errcode='22023';
    end if;
    insert into billing.sandbox_payment_orders(organization_id,appointment_id,amount_minor,currency)
    values(a.organization_id,a.id,total,'LKR') returning * into payment;
  end if;
  return jsonb_build_object('id',payment.id,'status',payment.status,'currency',payment.currency,
    'amount',trunc(payment.amount_minor::numeric/100,2)::text);
end;
$$;

-- The authenticated provider-facing worker is the only caller. Sandbox events never change real payment status.
create function api.record_payhere_sandbox_event(p_order uuid,p_amount_minor bigint,p_currency text,p_status text,p_provider_ref text)
returns text language plpgsql security definer set search_path='' as $$
declare payment billing.sandbox_payment_orders%rowtype;
declare next_status text;
declare disposition text;
begin
  if p_status is null or p_status not in ('2','0','-1','-2','-3') or char_length(p_provider_ref)>100 then
    raise exception 'Unsupported sandbox event.' using errcode='22023';
  end if;
  select * into payment from billing.sandbox_payment_orders where id=p_order for update;
  if not found then return 'unknown_order'; end if;
  if (payment.amount_minor,payment.currency) is distinct from (p_amount_minor,p_currency) then
    insert into billing.sandbox_payment_events(order_id,provider_status,disposition)
    values(p_order,p_status,'amount_mismatch') on conflict do nothing;
    return 'amount_mismatch';
  end if;
  next_status:=case p_status
    when '2' then 'paid' when '0' then 'pending' when '-1' then 'cancelled' when '-2' then 'failed' else 'chargeback' end;
  disposition:='ignored';
  if payment.status is distinct from next_status and payment.status<>'chargeback'
    and (payment.status<>'paid' or next_status='chargeback')
    and (payment.status not in ('cancelled','failed') or next_status in ('paid','chargeback')) then
    update billing.sandbox_payment_orders set status=next_status,updated_at=now() where id=p_order;
    disposition:='applied';
  end if;
  if not exists(select from billing.sandbox_payment_events e
    where e.order_id=p_order and e.provider_status=p_status and e.disposition in ('applied','ignored')) then
    insert into billing.sandbox_payment_events(order_id,provider_status,provider_reference,disposition)
    values(p_order,p_status,p_provider_ref,disposition);
  end if;
  return disposition;
end;
$$;

revoke all on function api.prepare_payhere_sandbox_order(uuid),api.record_payhere_sandbox_event(uuid,bigint,text,text,text)
  from public,anon,authenticated,service_role;
grant execute on function api.prepare_payhere_sandbox_order(uuid) to authenticated;
grant execute on function api.record_payhere_sandbox_event(uuid,bigint,text,text,text) to service_role;
notify pgrst,'reload schema';
commit;
