-- Velouvi Lite / Discover
-- Migration 001: Identity and security foundation
-- Source: Velouvi Database Design Report V1.0 (22 November 2026)
-- Apply through Supabase migrations. Do not run this against production until reviewed.

begin;

-- -----------------------------------------------------------------------------
-- 1. Schemas and extensions
-- -----------------------------------------------------------------------------

create schema if not exists core;
create schema if not exists private;

create extension if not exists pgcrypto with schema extensions;

-- Keep internal schemas out of the public API by default. If direct client access
-- is enabled later, expose only the intended schema and retain RLS on every table.

-- -----------------------------------------------------------------------------
-- 2. Shared updated_at trigger
-- -----------------------------------------------------------------------------

create or replace function core.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Profiles linked to Supabase Auth
-- -----------------------------------------------------------------------------

create table core.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_path text,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint profiles_display_name_length check (
    display_name is null or pg_catalog.char_length(display_name) <= 120
  )
);

create trigger profiles_set_updated_at
before update on core.profiles
for each row execute function core.set_updated_at();

-- Create a minimal profile when an Auth user is created. The profile deliberately
-- does not duplicate email/phone; Supabase Auth remains authoritative for those.
create or replace function core.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into core.profiles (id, display_name)
  values (
    new.id,
    nullif(pg_catalog.left(coalesce(new.raw_user_meta_data ->> 'display_name', ''), 120), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function core.handle_new_auth_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_create_profile on auth.users;
create trigger on_auth_user_created_create_profile
after insert on auth.users
for each row execute function core.handle_new_auth_user();

-- -----------------------------------------------------------------------------
-- 4. Organizations and locations (tenant boundary)
-- -----------------------------------------------------------------------------

create table core.organizations (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  slug text not null,
  legal_name text,
  status text not null default 'active',
  timezone text not null default 'Asia/Colombo',
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint organizations_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  constraint organizations_slug_format check (slug ~ '^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$'),
  constraint organizations_status_check check (status in ('active', 'suspended', 'archived')),
  constraint organizations_timezone_not_blank check (pg_catalog.length(pg_catalog.btrim(timezone)) > 0),
  constraint organizations_slug_unique unique (slug)
);

create trigger organizations_set_updated_at
before update on core.organizations
for each row execute function core.set_updated_at();

create table core.locations (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations (id) on delete restrict,
  name text not null,
  timezone text not null default 'Asia/Colombo',
  address_line_1 text,
  address_line_2 text,
  city text,
  district text,
  postal_code text,
  country_code char(2) not null default 'LK',
  is_default boolean not null default false,
  status text not null default 'active',
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint locations_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  constraint locations_status_check check (status in ('active', 'inactive', 'archived')),
  constraint locations_country_code_check check (country_code ~ '^[A-Z]{2}$'),
  constraint locations_org_id_unique unique (organization_id, id)
);

create unique index locations_one_default_per_org_idx
  on core.locations (organization_id)
  where is_default;

create index locations_org_status_idx
  on core.locations (organization_id, status);

create trigger locations_set_updated_at
before update on core.locations
for each row execute function core.set_updated_at();

-- -----------------------------------------------------------------------------
-- 5. Organization memberships and business role catalogue
-- -----------------------------------------------------------------------------

create table core.memberships (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations (id) on delete restrict,
  user_id uuid not null references auth.users (id) on delete restrict,
  status text not null default 'invited',
  invited_at timestamptz,
  activated_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint memberships_status_check check (status in ('invited', 'active', 'revoked')),
  constraint memberships_state_timestamps_check check (
    (status <> 'active' or activated_at is not null)
    and (status <> 'revoked' or revoked_at is not null)
  ),
  constraint memberships_one_identity_per_org unique (organization_id, user_id),
  constraint memberships_org_id_unique unique (organization_id, id)
);

create index memberships_user_status_idx
  on core.memberships (user_id, status);
create index memberships_org_status_idx
  on core.memberships (organization_id, status);

create trigger memberships_set_updated_at
before update on core.memberships
for each row execute function core.set_updated_at();

create table core.roles (
  id uuid primary key default extensions.gen_random_uuid(),
  code text not null unique,
  name text not null,
  description text,
  role_scope text not null default 'organization',
  is_system boolean not null default true,
  is_assignable boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  constraint roles_code_format check (code ~ '^[a-z][a-z0-9_]*$'),
  constraint roles_scope_check check (role_scope in ('organization', 'location'))
);

create table core.permissions (
  id uuid primary key default extensions.gen_random_uuid(),
  code text not null unique,
  description text not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint permissions_code_format check (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$')
);

create table core.role_permissions (
  role_id uuid not null references core.roles (id) on delete cascade,
  permission_id uuid not null references core.permissions (id) on delete cascade,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (role_id, permission_id)
);

create table core.role_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  membership_id uuid not null,
  role_id uuid not null references core.roles (id) on delete restrict,
  location_id uuid,
  assigned_by_membership_id uuid,
  assigned_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  constraint role_assignments_membership_fk
    foreign key (organization_id, membership_id)
    references core.memberships (organization_id, id) on delete restrict,
  constraint role_assignments_location_fk
    foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint role_assignments_assigner_fk
    foreign key (organization_id, assigned_by_membership_id)
    references core.memberships (organization_id, id) on delete restrict,
  constraint role_assignments_revocation_check check (revoked_at is null or revoked_at >= assigned_at)
);

create unique index role_assignments_active_unique_idx
  on core.role_assignments (organization_id, membership_id, role_id, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where revoked_at is null;

create index role_assignments_membership_active_idx
  on core.role_assignments (organization_id, membership_id)
  where revoked_at is null;
create index role_assignments_location_active_idx
  on core.role_assignments (organization_id, location_id)
  where revoked_at is null;

-- -----------------------------------------------------------------------------
-- 6. Platform access is separate from salon membership
-- -----------------------------------------------------------------------------

create table core.platform_roles (
  id uuid primary key default extensions.gen_random_uuid(),
  code text not null unique,
  name text not null,
  description text,
  created_at timestamptz not null default pg_catalog.now(),
  constraint platform_roles_code_format check (code ~ '^[a-z][a-z0-9_]*$')
);

create table core.platform_permissions (
  id uuid primary key default extensions.gen_random_uuid(),
  code text not null unique,
  description text not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint platform_permissions_code_format check (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$')
);

create table core.platform_role_permissions (
  platform_role_id uuid not null references core.platform_roles (id) on delete cascade,
  platform_permission_id uuid not null references core.platform_permissions (id) on delete cascade,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (platform_role_id, platform_permission_id)
);

create table core.platform_memberships (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete restrict,
  status text not null default 'active',
  created_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  constraint platform_memberships_status_check check (status in ('active', 'revoked')),
  constraint platform_memberships_state_check check (
    (status = 'active' and revoked_at is null)
    or (status = 'revoked' and revoked_at is not null)
  ),
  constraint platform_memberships_one_identity unique (user_id),
  constraint platform_memberships_id_user_unique unique (id, user_id)
);

create table core.platform_role_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  platform_membership_id uuid not null references core.platform_memberships (id) on delete restrict,
  platform_role_id uuid not null references core.platform_roles (id) on delete restrict,
  assigned_by_user_id uuid references auth.users (id) on delete set null,
  assigned_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  constraint platform_role_assignments_revocation_check check (revoked_at is null or revoked_at >= assigned_at)
);

create unique index platform_role_assignments_active_unique_idx
  on core.platform_role_assignments (platform_membership_id, platform_role_id)
  where revoked_at is null;

-- -----------------------------------------------------------------------------
-- 7. Invitations and purpose-bound support access
-- -----------------------------------------------------------------------------

create table core.invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations (id) on delete restrict,
  intended_recipient text not null,
  token_hash text not null unique,
  role_id uuid not null references core.roles (id) on delete restrict,
  location_id uuid,
  invited_by_membership_id uuid not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  constraint invitations_recipient_not_blank check (pg_catalog.length(pg_catalog.btrim(intended_recipient)) > 0),
  constraint invitations_token_hash_not_blank check (pg_catalog.length(pg_catalog.btrim(token_hash)) > 0),
  constraint invitations_expiry_after_creation check (expires_at > created_at),
  constraint invitations_org_id_unique unique (organization_id, id),
  constraint invitations_location_fk
    foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint invitations_inviter_fk
    foreign key (organization_id, invited_by_membership_id)
    references core.memberships (organization_id, id) on delete restrict
);

create index invitations_org_expiry_idx
  on core.invitations (organization_id, expires_at)
  where consumed_at is null and revoked_at is null;

create table core.support_access_grants (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations (id) on delete restrict,
  requested_by_user_id uuid not null references auth.users (id) on delete restrict,
  approved_by_user_id uuid references auth.users (id) on delete restrict,
  purpose text not null,
  ticket_reference text,
  status text not null default 'requested',
  starts_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  constraint support_access_purpose_not_blank check (pg_catalog.length(pg_catalog.btrim(purpose)) > 0),
  constraint support_access_status_check check (status in ('requested', 'approved', 'denied', 'expired', 'revoked')),
  constraint support_access_approval_check check (
    status not in ('approved', 'expired', 'revoked')
    or (approved_by_user_id is not null and starts_at is not null and expires_at is not null)
  ),
  constraint support_access_window_check check (
    expires_at is null or starts_at is null or expires_at > starts_at
  ),
  constraint support_access_no_self_approval check (
    approved_by_user_id is null or approved_by_user_id <> requested_by_user_id
  ),
  constraint support_access_org_id_unique unique (organization_id, id)
);

create index support_access_org_active_idx
  on core.support_access_grants (organization_id, starts_at, expires_at)
  where status = 'approved' and revoked_at is null;

-- -----------------------------------------------------------------------------
-- 8. Private audit event foundation
-- -----------------------------------------------------------------------------

create table private.audit_events (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid references core.organizations (id) on delete restrict,
  actor_user_id uuid references auth.users (id) on delete set null,
  action text not null,
  entity_schema text,
  entity_table text,
  entity_id uuid,
  occurred_at timestamptz not null default pg_catalog.now(),
  correlation_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  constraint audit_action_not_blank check (pg_catalog.length(pg_catalog.btrim(action)) > 0),
  constraint audit_metadata_object check (pg_catalog.jsonb_typeof(metadata) = 'object')
);

create index audit_events_org_time_idx
  on private.audit_events (organization_id, occurred_at desc);
create index audit_events_actor_time_idx
  on private.audit_events (actor_user_id, occurred_at desc);

-- -----------------------------------------------------------------------------
-- 9. Seed initial permission and role catalogues
-- -----------------------------------------------------------------------------

insert into core.permissions (code, description) values
  ('organization.read', 'View organization details'),
  ('organization.update', 'Update organization settings'),
  ('locations.read', 'View organization locations'),
  ('locations.manage', 'Create and manage organization locations'),
  ('members.read', 'View organization memberships'),
  ('members.invite', 'Invite users to the organization'),
  ('members.manage', 'Activate, revoke and manage memberships'),
  ('roles.read', 'View role assignments'),
  ('roles.assign', 'Assign roles within the actor authority'),
  ('settings.manage', 'Manage business settings'),
  ('billing.read', 'View organization billing'),
  ('billing.manage', 'Manage organization billing')
on conflict (code) do nothing;

insert into core.roles (code, name, description, role_scope) values
  ('owner', 'Business Owner', 'Owner-level control over the organization and its branches', 'organization'),
  ('manager', 'Manager', 'Operational management within assigned organization or branch scope', 'location'),
  ('team_member', 'Team Member', 'Access to assigned work and minimum operational information', 'location')
on conflict (code) do nothing;

-- Initial least-privilege grants. Fine-grained operational permissions will be
-- added in the relevant later migrations as those modules are implemented.
insert into core.role_permissions (role_id, permission_id)
select r.id, p.id
from core.roles r
join core.permissions p on p.code in (
  'organization.read', 'organization.update',
  'locations.read', 'locations.manage',
  'members.read', 'members.invite', 'members.manage',
  'roles.read', 'roles.assign', 'settings.manage',
  'billing.read', 'billing.manage'
)
where r.code = 'owner'
on conflict do nothing;

insert into core.role_permissions (role_id, permission_id)
select r.id, p.id
from core.roles r
join core.permissions p on p.code in (
  'organization.read', 'locations.read', 'members.read', 'roles.read'
)
where r.code = 'manager'
on conflict do nothing;

insert into core.role_permissions (role_id, permission_id)
select r.id, p.id
from core.roles r
join core.permissions p on p.code in ('organization.read', 'locations.read')
where r.code = 'team_member'
on conflict do nothing;

insert into core.platform_permissions (code, description) values
  ('platform.dashboard.read', 'Access the platform administration dashboard'),
  ('platform.organizations.read', 'View organization-level platform metadata'),
  ('platform.organizations.manage', 'Manage organization onboarding and status'),
  ('platform.moderation.manage', 'Moderate public marketplace listings'),
  ('platform.billing.read', 'View platform billing operations'),
  ('platform.support.manage', 'Manage support workflows and access requests')
on conflict (code) do nothing;

insert into core.platform_roles (code, name, description) values
  ('company_admin', 'Company Admin', 'Platform administration; salon private access still requires an explicit support grant'),
  ('operations', 'Operations', 'Platform operations and onboarding'),
  ('support', 'Support', 'Purpose-bound customer support'),
  ('billing', 'Billing', 'Platform billing operations')
on conflict (code) do nothing;

insert into core.platform_role_permissions (platform_role_id, platform_permission_id)
select r.id, p.id
from core.platform_roles r
cross join core.platform_permissions p
where r.code = 'company_admin'
on conflict do nothing;

insert into core.platform_role_permissions (platform_role_id, platform_permission_id)
select r.id, p.id
from core.platform_roles r
join core.platform_permissions p on p.code in (
  'platform.dashboard.read', 'platform.organizations.read', 'platform.organizations.manage', 'platform.moderation.manage'
)
where r.code = 'operations'
on conflict do nothing;

insert into core.platform_role_permissions (platform_role_id, platform_permission_id)
select r.id, p.id
from core.platform_roles r
join core.platform_permissions p on p.code in ('platform.dashboard.read', 'platform.organizations.read', 'platform.support.manage')
where r.code = 'support'
on conflict do nothing;

insert into core.platform_role_permissions (platform_role_id, platform_permission_id)
select r.id, p.id
from core.platform_roles r
join core.platform_permissions p on p.code in ('platform.dashboard.read', 'platform.billing.read')
where r.code = 'billing'
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 10. Permission helper functions
-- -----------------------------------------------------------------------------

-- This function checks the current Auth user against active membership, an
-- active role assignment, the requested permission and its organization/branch
-- scope. A NULL p_location_id means an organization-wide permission check.
create or replace function core.has_org_permission(
  p_organization_id uuid,
  p_permission_code text,
  p_location_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from core.memberships m
    join core.role_assignments ra
      on ra.organization_id = m.organization_id
     and ra.membership_id = m.id
     and ra.revoked_at is null
    join core.roles r on r.id = ra.role_id
    join core.role_permissions rp on rp.role_id = r.id
    join core.permissions p on p.id = rp.permission_id
    where m.organization_id = p_organization_id
      and m.user_id = auth.uid()
      and m.status = 'active'
      and p.code = p_permission_code
      and (
        (p_location_id is null and ra.location_id is null)
        or (p_location_id is not null and (ra.location_id is null or ra.location_id = p_location_id))
      )
  );
$$;

create or replace function core.is_active_org_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from core.memberships m
    where m.organization_id = p_organization_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  );
$$;

create or replace function core.has_platform_permission(p_permission_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from core.platform_memberships pm
    join core.platform_role_assignments pra
      on pra.platform_membership_id = pm.id
     and pra.revoked_at is null
    join core.platform_role_permissions prp on prp.platform_role_id = pra.platform_role_id
    join core.platform_permissions pp on pp.id = prp.platform_permission_id
    where pm.user_id = auth.uid()
      and pm.status = 'active'
      and pp.code = p_permission_code
  );
$$;

revoke all on function core.has_org_permission(uuid, text, uuid) from public, anon;
revoke all on function core.is_active_org_member(uuid) from public, anon;
revoke all on function core.has_platform_permission(text) from public, anon;
grant execute on function core.has_org_permission(uuid, text, uuid) to authenticated;
grant execute on function core.is_active_org_member(uuid) to authenticated;
grant execute on function core.has_platform_permission(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 11. Row Level Security
-- -----------------------------------------------------------------------------

alter table core.profiles enable row level security;
alter table core.organizations enable row level security;
alter table core.locations enable row level security;
alter table core.memberships enable row level security;
alter table core.roles enable row level security;
alter table core.permissions enable row level security;
alter table core.role_permissions enable row level security;
alter table core.role_assignments enable row level security;
alter table core.platform_roles enable row level security;
alter table core.platform_permissions enable row level security;
alter table core.platform_role_permissions enable row level security;
alter table core.platform_memberships enable row level security;
alter table core.platform_role_assignments enable row level security;
alter table core.invitations enable row level security;
alter table core.support_access_grants enable row level security;
alter table private.audit_events enable row level security;

-- Profiles: a user can read/update only their own profile.
create policy profiles_select_self on core.profiles
for select to authenticated
using (id = (select auth.uid()));

create policy profiles_update_self on core.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

-- Organization records: only active members can read; updates require permission.
create policy organizations_select_member on core.organizations
for select to authenticated
using (core.is_active_org_member(id));

-- Organization creation and changes are performed through controlled
-- server-side onboarding/settings functions.

-- Locations: active organization members can read; location management requires
-- an organization-wide locations.manage permission.
create policy locations_select_authorized_scope
on core.locations
for select
to authenticated
using (
  core.has_org_permission(
    organization_id,
    'locations.read',
    id
  )
);

-- Location creation and changes are performed through controlled
-- server-side branch-management functions.

-- Memberships and assignments: users can see their own membership. Authorized
-- managers/owners can see and manage memberships and assignments.
create policy memberships_select_self_or_manager on core.memberships
for select to authenticated
using (
  user_id = (select auth.uid())
  or core.has_org_permission(organization_id, 'members.read')
);

-- Membership changes are performed through audited server-side onboarding and
-- invitation workflows, not direct client table writes.

create policy roles_select_authenticated on core.roles
for select to authenticated
using (true);

create policy permissions_select_authenticated on core.permissions
for select to authenticated
using (true);

create policy role_permissions_select_authenticated on core.role_permissions
for select to authenticated
using (true);

create policy role_assignments_select_self_or_manager on core.role_assignments
for select to authenticated
using (
  exists (
    select 1 from core.memberships m
    where m.id = role_assignments.membership_id
      and m.organization_id = role_assignments.organization_id
      and m.user_id = (select auth.uid())
  )
  or core.has_org_permission(role_assignments.organization_id, 'roles.read', role_assignments.location_id)
);

-- Role assignment changes are performed through a controlled server-side
-- function that enforces assigner authority and branch scope.

-- Platform catalogues are visible to authenticated users, but assignments and
-- platform memberships are visible only to authorized platform administrators.
create policy platform_roles_select_authenticated on core.platform_roles
for select to authenticated using (true);
create policy platform_permissions_select_authenticated on core.platform_permissions
for select to authenticated using (true);
create policy platform_role_permissions_select_authenticated on core.platform_role_permissions
for select to authenticated using (true);

create policy platform_memberships_select_self_or_admin on core.platform_memberships
for select to authenticated
using (user_id = (select auth.uid()) or core.has_platform_permission('platform.dashboard.read'));

-- Platform membership and role changes are performed through audited
-- server-side administration workflows.

-- Invitations: no direct authenticated reads of token material. Creation and
-- revocation are handled through privileged server-side endpoints in a later step.
-- Support grants and audit events likewise have no client-facing policies here.

-- -----------------------------------------------------------------------------
-- 12. Explicit grants and default-deny boundaries
-- -----------------------------------------------------------------------------

revoke all on all tables in schema core from anon, authenticated;
revoke all on all tables in schema private from anon, authenticated;

-- Grant only the table operations required by the RLS policies above.
grant select, update on core.profiles to authenticated;
grant select on core.organizations, core.locations, core.memberships to authenticated;
grant select on core.roles, core.permissions, core.role_permissions to authenticated;
grant select on core.role_assignments to authenticated;
grant select on core.platform_roles, core.platform_permissions, core.platform_role_permissions to authenticated;
grant select on core.platform_memberships, core.platform_role_assignments to authenticated;

-- No client table privileges for invitations, support grants or private audit.
-- These records are manipulated through carefully authorized server functions.

grant usage on schema core to authenticated, service_role;
grant all on all tables in schema core to service_role;
grant usage on schema private to service_role;
grant all on all tables in schema private to service_role;

commit;

-- Restrict profile updates to user-editable fields
revoke update on table core.profiles from authenticated;

grant update (display_name, avatar_path)
on table core.profiles
to authenticated;
