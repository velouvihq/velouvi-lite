begin;

create function api.issue_team_invitation(p_location uuid,p_email text,p_role text default 'team_member')
returns text language plpgsql security definer set search_path='' as $$
declare org uuid;
declare inviter uuid;
declare role_id uuid;
declare email text:=lower(btrim(coalesce(p_email,'')));
declare token text;
begin
  select l.organization_id into org from core.locations l where l.id=p_location and l.status='active';
  if not (core.has_org_permission(org,'members.invite') and core.has_org_permission(org,'roles.assign')) then
    raise exception 'Team invitation access denied.' using errcode='42501';
  end if;
  if char_length(email)>254 or email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or p_role is null or p_role not in ('manager','team_member') then
    raise exception 'Choose a valid email and a branch team role.' using errcode='22023';
  end if;
  perform private.lock_booking_org(org);
  if not (core.has_org_permission(org,'members.invite') and core.has_org_permission(org,'roles.assign')) then
    raise exception 'Team invitation access denied.' using errcode='42501';
  end if;
  select m.id into inviter from core.memberships m
  where m.organization_id=org and m.user_id=auth.uid() and m.status='active';
  select r.id into role_id from core.roles r where r.code=p_role and r.is_assignable and r.role_scope='location';
  if role_id is null then raise exception 'This role is unavailable.' using errcode='22023'; end if;
  update core.invitations i set revoked_at=now()
  where i.organization_id=org and i.location_id=p_location and i.intended_recipient=email
    and i.consumed_at is null and i.revoked_at is null;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into core.invitations(organization_id,intended_recipient,token_hash,role_id,location_id,invited_by_membership_id,expires_at)
  values (org,email,encode(extensions.digest(token,'sha256'),'hex'),role_id,p_location,inviter,now()+interval '2 days');
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values (org,auth.uid(),'team.invitation_issued','core','locations',p_location);
  return token;
end;
$$;

create function api.accept_team_invitation(p_token text)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
declare invite core.invitations%rowtype;
declare h text;
declare member uuid;
declare member_status text;
begin
  if uid is null or p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'This invitation cannot be accepted.' using errcode='42501';
  end if;
  h:=encode(extensions.digest(p_token,'sha256'),'hex');
  select * into invite from core.invitations where token_hash=h;
  if not found then raise exception 'This invitation cannot be accepted.' using errcode='42501'; end if;
  perform private.lock_booking_org(invite.organization_id);
  select * into invite from core.invitations where token_hash=h for update;
  if invite.revoked_at is not null or invite.consumed_at is not null or invite.expires_at<=now()
    or not exists(select from core.roles r where r.id=invite.role_id and r.code in ('manager','team_member') and r.is_assignable)
    or not exists(select from core.locations l where (l.organization_id,l.id)=(invite.organization_id,invite.location_id)
      and l.status='active')
    or not exists(select from auth.users u where u.id=uid and u.email_confirmed_at is not null
      and lower(btrim(u.email))=invite.intended_recipient)
    or not exists(select from core.memberships inviter join core.role_assignments ra
      on (ra.organization_id,ra.membership_id)=(inviter.organization_id,inviter.id)
      join core.roles r on r.id=ra.role_id
      where (inviter.organization_id,inviter.id)=(invite.organization_id,invite.invited_by_membership_id)
        and inviter.status='active' and ra.revoked_at is null and ra.location_id is null and r.code='owner') then
    raise exception 'This invitation cannot be accepted.' using errcode='42501';
  end if;
  select m.id,m.status into member,member_status from core.memberships m
  where m.organization_id=invite.organization_id and m.user_id=uid for update;
  if member_status='revoked' then
    raise exception 'This invitation cannot be accepted.' using errcode='42501';
  end if;
  if member is null then
    insert into core.memberships(organization_id,user_id,status,activated_at)
    values (invite.organization_id,uid,'active',now()) returning id into member;
  elsif member_status='invited' then
    update core.memberships set status='active',activated_at=now() where id=member;
  end if;
  insert into core.role_assignments(organization_id,membership_id,role_id,location_id,assigned_by_membership_id)
  values(invite.organization_id,member,invite.role_id,invite.location_id,invite.invited_by_membership_id) on conflict do nothing;
  update core.invitations set consumed_at=now() where id=invite.id;
  insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
  values(invite.organization_id,uid,'team.invitation_accepted','core','memberships',member);
  return invite.location_id;
end;
$$;

create function api.booking_team(p_location uuid)
returns table(assignment_id uuid,display_name text,role text)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from core.locations where id=p_location;
  if not core.has_org_permission(org,'members.manage') then
    raise exception 'Team management access denied.' using errcode='42501';
  end if;
  return query select a.id,coalesce(p.display_name,'Team member'),r.code
  from core.role_assignments a
  join core.memberships m on (m.organization_id,m.id)=(a.organization_id,a.membership_id)
  join core.roles r on r.id=a.role_id
  left join core.profiles p on p.id=m.user_id
  where a.organization_id=org and a.location_id=p_location and a.revoked_at is null and m.status='active'
    and r.code in ('manager','team_member')
  order by p.display_name,r.code,a.id;
end;
$$;

create function api.revoke_booking_team_assignment(p_assignment uuid)
returns void language plpgsql security definer set search_path='' as $$
declare assignment core.role_assignments%rowtype;
declare email text;
begin
  select a.* into assignment from core.role_assignments a join core.roles r on r.id=a.role_id
  where a.id=p_assignment and a.location_id is not null and r.code in ('manager','team_member');
  if not (core.has_org_permission(assignment.organization_id,'members.manage')
    and core.has_org_permission(assignment.organization_id,'roles.assign')) then
    raise exception 'Team management access denied.' using errcode='42501';
  end if;
  perform private.lock_booking_org(assignment.organization_id);
  if not (core.has_org_permission(assignment.organization_id,'members.manage')
    and core.has_org_permission(assignment.organization_id,'roles.assign')) then
    raise exception 'Team management access denied.' using errcode='42501';
  end if;
  update core.role_assignments set revoked_at=now() where id=assignment.id and revoked_at is null;
  if found then
    select lower(btrim(u.email)) into email from core.memberships m join auth.users u on u.id=m.user_id
    where (m.organization_id,m.id)=(assignment.organization_id,assignment.membership_id);
    update core.invitations set revoked_at=now()
    where organization_id=assignment.organization_id and location_id=assignment.location_id
      and intended_recipient=email and consumed_at is null and revoked_at is null;
    insert into private.audit_events(organization_id,actor_user_id,action,entity_schema,entity_table,entity_id)
    values(assignment.organization_id,auth.uid(),'team.assignment_revoked','core','role_assignments',assignment.id);
  end if;
end;
$$;

revoke all on function api.issue_team_invitation(uuid,text,text),api.accept_team_invitation(text),
  api.booking_team(uuid),api.revoke_booking_team_assignment(uuid) from public,anon,authenticated,service_role;
grant execute on function api.issue_team_invitation(uuid,text,text),api.accept_team_invitation(text),
  api.booking_team(uuid),api.revoke_booking_team_assignment(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
