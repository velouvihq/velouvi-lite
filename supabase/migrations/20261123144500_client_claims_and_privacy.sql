begin;

create function api.issue_client_claim(p_client uuid)
returns text language plpgsql security definer set search_path='' as $$
declare org uuid;
declare token text;
begin
  select organization_id into org from core.clients where id=p_client and status='active';
  if not core.has_org_permission(org,'clients.manage') then
    raise exception 'Client management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(org);
  if not core.has_org_permission(org,'clients.manage') then
    raise exception 'Client management access denied.' using errcode='42501';
  end if;
  if not exists(select from private.client_contacts c
    where c.organization_id=org and c.client_id=p_client and c.contact_type='email' and c.is_primary)
    or exists(select from core.client_account_links l where l.organization_id=org and l.client_id=p_client and l.revoked_at is null) then
    raise exception 'The client needs a primary email and must be unlinked.' using errcode='22023';
  end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  update private.client_claim_tokens set revoked_at=now()
  where organization_id=org and client_id=p_client and consumed_at is null and revoked_at is null;
  insert into private.client_claim_tokens(organization_id,client_id,token_hash,expires_at)
  values(org,p_client,encode(extensions.digest(token,'sha256'),'hex'),now()+interval '24 hours');
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values(org,auth.uid(),'client.claim_issued','core','clients',p_client);
  return token;
end;
$$;

create function api.redeem_client_claim(p_token text)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
declare t private.client_claim_tokens%rowtype;
declare h text;
begin
  if uid is null or p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'This claim cannot be redeemed.' using errcode='42501';
  end if;
  h:=encode(extensions.digest(p_token,'sha256'),'hex');
  select * into t from private.client_claim_tokens where token_hash=h;
  if not found then raise exception 'This claim cannot be redeemed.' using errcode='42501'; end if;
  perform private.lock_booking_org(t.organization_id);
  select * into t from private.client_claim_tokens where token_hash=h for update;
  if t.consumed_at is not null or t.revoked_at is not null or t.expires_at<=now()
    or not exists (
      select from core.clients c join private.client_contacts contact
        on (contact.organization_id,contact.client_id)=(c.organization_id,c.id)
      join auth.users u on u.id=uid and u.email_confirmed_at is not null
        and lower(btrim(u.email))=contact.normalized_value
      where (c.organization_id,c.id)=(t.organization_id,t.client_id) and c.status='active'
        and contact.contact_type='email' and contact.is_primary
    ) then raise exception 'This claim cannot be redeemed.' using errcode='42501'; end if;
  begin
    insert into core.client_account_links(organization_id,client_id,user_id,proof_type)
    values(t.organization_id,t.client_id,uid,'booking_claim');
  exception when unique_violation then
    raise exception 'This claim cannot be redeemed.' using errcode='42501';
  end;
  update private.client_claim_tokens set consumed_at=now() where id=t.id;
  update private.client_contacts set verified_at=now()
  where organization_id=t.organization_id and client_id=t.client_id and contact_type='email' and is_primary;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values(t.organization_id,uid,'client.claim_redeemed','core','clients',t.client_id);
  return t.client_id;
end;
$$;

create function private.can_manage_client(p_org uuid,p_client uuid)
returns boolean language sql stable set search_path='' as $$
  select core.has_org_permission(p_org,'clients.manage') or exists(
    select from core.client_account_links l
    where (l.organization_id,l.client_id)=(p_org,p_client) and l.user_id=auth.uid() and l.revoked_at is null
  )
$$;

create function api.client_contacts(p_client uuid)
returns table(contact_type text,display_value text,is_primary boolean,is_verified boolean)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select c.organization_id into org from core.clients c where c.id=p_client and c.status='active';
  if not private.can_manage_client(org,p_client) then
    raise exception 'Client access denied.' using errcode='42501';
  end if;
  return query select c.contact_type,c.display_value,c.is_primary,c.verified_at is not null
  from private.client_contacts c where (c.organization_id,c.client_id)=(org,p_client)
  order by c.is_primary desc,c.contact_type,c.created_at;
end;
$$;

create function api.record_client_consent(p_client uuid,p_purpose text,p_channel text,p_notice text,p_allowed boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
declare created uuid;
begin
  select organization_id into org from core.clients where id=p_client and status='active';
  if not private.can_manage_client(org,p_client) then
    raise exception 'Client access denied.' using errcode='42501';
  end if;
  if char_length(btrim(p_purpose)) not between 1 and 120 or char_length(btrim(p_notice)) not between 1 and 120
    or p_allowed is null then raise exception 'Supply the purpose, notice and consent decision.' using errcode='22023'; end if;
  perform private.lock_booking_org(org);
  if not private.can_manage_client(org,p_client) then
    raise exception 'Client access denied.' using errcode='42501';
  end if;
  insert into core.client_consents(organization_id,client_id,purpose,channel,notice_version,consented,recorded_by_user_id)
  values (org,p_client,btrim(p_purpose),p_channel,btrim(p_notice),p_allowed,auth.uid()) returning id into created;
  return created;
end;
$$;

create function api.delegate_client_booking(p_appointment uuid,p_recipient uuid,p_expires timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare a ops.appointments%rowtype;
declare result uuid;
begin
  select * into a from ops.appointments where id=p_appointment;
  if a.primary_client_id is null or not private.can_manage_client(a.organization_id,a.primary_client_id) then
    raise exception 'Delegation access denied.' using errcode='42501';
  end if;
  if p_expires is null or not isfinite(p_expires) or p_expires<=now() or p_expires>now()+interval '30 days'
    or p_recipient is null or not exists(select from auth.users where id=p_recipient and email_confirmed_at is not null) then
    raise exception 'Choose a verified recipient and an expiry within 30 days.' using errcode='22023';
  end if;
  perform private.lock_booking_org(a.organization_id);
  if not private.can_manage_client(a.organization_id,a.primary_client_id) then
    raise exception 'Delegation access denied.' using errcode='42501';
  end if;
  insert into ops.client_delegated_grants(organization_id,appointment_id,granted_to_user_id,permission_scope,
    expires_at,created_by_user_id)
  values(a.organization_id,a.id,p_recipient,'booking_read',p_expires,auth.uid())
  on conflict(organization_id,appointment_id,granted_to_user_id,permission_scope) where revoked_at is null
  do update set expires_at=excluded.expires_at returning id into result;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values(a.organization_id,auth.uid(),'appointment.delegated','ops','client_delegated_grants',result);
  return result;
end;
$$;

create function api.revoke_client_delegation(p_grant uuid)
returns void language plpgsql security definer set search_path='' as $$
declare a ops.appointments%rowtype;
begin
  select ap.* into a from ops.client_delegated_grants g
  join ops.appointments ap on (ap.organization_id,ap.id)=(g.organization_id,g.appointment_id)
  where g.id=p_grant;
  if a.primary_client_id is null or not private.can_manage_client(a.organization_id,a.primary_client_id) then
    raise exception 'Delegation access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(a.organization_id);
  if not private.can_manage_client(a.organization_id,a.primary_client_id) then
    raise exception 'Delegation access denied.' using errcode='42501';
  end if;
  update ops.client_delegated_grants set revoked_at=now() where id=p_grant and revoked_at is null;
  if found then
    insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
    values(a.organization_id,auth.uid(),'appointment.delegation_revoked','ops','client_delegated_grants',p_grant);
  end if;
end;
$$;

-- A curated customer projection avoids exposing internal IDs, CRM data or guest contact details.
create function api.my_appointments()
returns table(id uuid,studio text,location text,timezone text,starts_at timestamptz,ends_at timestamptz,status text,service text)
language sql stable security definer set search_path='' as $$
  select a.id,o.name,l.name,l.timezone,a.starts_at,a.ends_at,a.status,
    (select string_agg(i.item_name_snapshot,', ' order by i.sort_order,i.id) from ops.appointment_items i
     where (i.organization_id,i.appointment_id)=(a.organization_id,a.id))
  from ops.appointments a
  join core.organizations o on o.id=a.organization_id
  join core.locations l on (l.organization_id,l.id)=(a.organization_id,a.location_id)
  where auth.uid() is not null and (
    exists(select from core.client_account_links link where (link.organization_id,link.client_id)=(a.organization_id,a.primary_client_id)
           and link.user_id=auth.uid() and link.revoked_at is null)
    or exists(select from ops.client_delegated_grants g where (g.organization_id,g.appointment_id)=(a.organization_id,a.id)
           and g.granted_to_user_id=auth.uid() and g.permission_scope='booking_read' and g.revoked_at is null and g.expires_at>now()))
  order by a.starts_at desc,a.id limit 100
$$;

create function api.booking_clients(p_org uuid)
returns table(id uuid,display_name text,is_linked boolean)
language plpgsql stable security definer set search_path='' as $$
begin
  if not core.has_org_permission(p_org,'clients.read') then
    raise exception 'Client directory access denied.' using errcode='42501';
  end if;
  return query select c.id,c.display_name,exists(select from core.client_account_links link
    where (link.organization_id,link.client_id)=(c.organization_id,c.id) and link.revoked_at is null)
  from core.clients c where c.organization_id=p_org and c.status='active'
  order by c.display_name,c.id limit 200;
end;
$$;

-- A merge leaves both client IDs and prior consent records in place for audit.
-- Linked profiles and delegated appointments require a separately reviewed workflow.
create function api.merge_unlinked_clients(p_source uuid,p_survivor uuid,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
declare result uuid;
begin
  select organization_id into org from core.clients where id=p_source;
  if not core.has_org_permission(org,'clients.manage') then
    raise exception 'Client management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(org);
  if not core.has_org_permission(org,'clients.manage') then
    raise exception 'Client management access denied.' using errcode='42501';
  end if;
  if p_source=p_survivor or char_length(btrim(coalesce(p_reason,''))) not between 3 and 500
    or (select count(*) from core.clients where organization_id=org and id in (p_source,p_survivor) and status='active')<>2
    or exists (select from core.client_account_links where organization_id=org and client_id in (p_source,p_survivor)
       and revoked_at is null)
    or exists (select from ops.client_delegated_grants g join ops.appointments a
       on (a.organization_id,a.id)=(g.organization_id,g.appointment_id)
       where g.organization_id=org and a.primary_client_id in (p_source,p_survivor)
         and g.revoked_at is null and g.expires_at>now()) then
    raise exception 'Choose two active, unlinked clients in this organization, with no active delegation, and record the reason.'
      using errcode='22023';
  end if;
  update core.clients set status='merged' where organization_id=org and id=p_source;
  update private.client_claim_tokens set revoked_at=now()
  where organization_id=org and client_id in (p_source,p_survivor) and consumed_at is null and revoked_at is null;
  insert into core.client_merge_events(organization_id,survivor_client_id,merged_client_id,merged_by_user_id,reason)
  values(org,p_survivor,p_source,auth.uid(),btrim(p_reason)) returning id into result;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id,
    metadata) values(org,auth.uid(),'client.merge_recorded','core','clients',p_source,jsonb_build_object('survivor',p_survivor));
  return result;
end;
$$;

revoke all on function api.booking_clients(uuid),api.merge_unlinked_clients(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.booking_clients(uuid),api.merge_unlinked_clients(uuid,uuid,text) to authenticated;

revoke all on function private.can_manage_client(uuid,uuid) from public,anon,authenticated;
revoke all on function api.issue_client_claim(uuid),api.redeem_client_claim(text),api.client_contacts(uuid),
  api.record_client_consent(uuid,text,text,text,boolean),api.delegate_client_booking(uuid,uuid,timestamptz),
  api.revoke_client_delegation(uuid),api.my_appointments() from public,anon,authenticated,service_role;
grant execute on function api.issue_client_claim(uuid),api.redeem_client_claim(text),api.client_contacts(uuid),
  api.record_client_consent(uuid,text,text,text,boolean),api.delegate_client_booking(uuid,uuid,timestamptz),
  api.revoke_client_delegation(uuid),api.my_appointments() to authenticated;
notify pgrst, 'reload schema';
commit;
