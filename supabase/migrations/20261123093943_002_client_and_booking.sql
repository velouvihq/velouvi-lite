-- Velouvi Lite / Discover
-- Migration 002: Client, catalogue, scheduling and booking foundation
-- Built against Migration 001 (identity_and_security).
-- Apply only through reviewed Supabase migrations; validate locally before staging.

begin;

-- -----------------------------------------------------------------------------
-- 1. Schemas and required extension
-- -----------------------------------------------------------------------------

create schema if not exists ops;
create schema if not exists commerce;

create extension if not exists btree_gist with schema extensions;

-- -----------------------------------------------------------------------------
-- 2. Shared timestamps and business categories
-- -----------------------------------------------------------------------------

create table core.business_categories (
  id uuid primary key default extensions.gen_random_uuid(),
  code text not null unique,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  constraint business_categories_code_format check (code ~ '^[a-z][a-z0-9_]*$'),
  constraint business_categories_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0)
);

create table core.organization_categories (
  organization_id uuid not null references core.organizations(id) on delete restrict,
  category_id uuid not null references core.business_categories(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (organization_id, category_id)
);

-- Category codes are intentionally not seeded here: the design report specifies
-- eight codes but does not enumerate their canonical names/codes.

-- -----------------------------------------------------------------------------
-- 3. Staff identity and branch placement
-- -----------------------------------------------------------------------------

create table core.staff_profiles (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations(id) on delete restrict,
  user_id uuid references auth.users(id) on delete set null,
  display_name text not null,
  public_name text,
  bio text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint staff_profiles_org_id_unique unique (organization_id, id),
  constraint staff_profiles_display_name_not_blank check (pg_catalog.length(pg_catalog.btrim(display_name)) > 0),
  constraint staff_profiles_display_name_length check (pg_catalog.char_length(display_name) <= 120),
  constraint staff_profiles_public_name_length check (public_name is null or pg_catalog.char_length(public_name) <= 120),
  constraint staff_profiles_bio_length check (bio is null or pg_catalog.char_length(bio) <= 2000)
);

create unique index staff_profiles_org_user_active_unique_idx
  on core.staff_profiles (organization_id, user_id)
  where user_id is not null and is_active;
create index staff_profiles_org_active_idx
  on core.staff_profiles (organization_id, is_active);
create trigger staff_profiles_set_updated_at
before update on core.staff_profiles
for each row execute function core.set_updated_at();

create table core.staff_locations (
  organization_id uuid not null,
  staff_profile_id uuid not null,
  location_id uuid not null,
  is_primary boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (organization_id, staff_profile_id, location_id),
  constraint staff_locations_staff_fk foreign key (organization_id, staff_profile_id)
    references core.staff_profiles (organization_id, id) on delete restrict,
  constraint staff_locations_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict
);
create index staff_locations_location_active_idx
  on core.staff_locations (organization_id, location_id, is_active);
create unique index staff_locations_one_primary_idx
  on core.staff_locations (organization_id, staff_profile_id)
  where is_primary and is_active;

-- -----------------------------------------------------------------------------
-- 4. Tenant-scoped client identity and restricted contact details
-- -----------------------------------------------------------------------------

create table core.clients (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations(id) on delete restrict,
  display_name text not null,
  notes text,
  status text not null default 'active',
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint clients_org_id_unique unique (organization_id, id),
  constraint clients_display_name_not_blank check (pg_catalog.length(pg_catalog.btrim(display_name)) > 0),
  constraint clients_display_name_length check (pg_catalog.char_length(display_name) <= 160),
  constraint clients_notes_length check (notes is null or pg_catalog.char_length(notes) <= 5000),
  constraint clients_status_check check (status in ('active', 'merged', 'archived'))
);
create index clients_org_status_name_idx on core.clients (organization_id, status, display_name);
create trigger clients_set_updated_at
before update on core.clients
for each row execute function core.set_updated_at();

-- Contact values live in the private schema. A normalized phone/email is NOT
-- unique: family members may legitimately share a phone number or email address.
create table private.client_contacts (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  client_id uuid not null,
  contact_type text not null,
  normalized_value text not null,
  display_value text not null,
  is_primary boolean not null default false,
  verified_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  constraint client_contacts_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint client_contacts_type_check check (contact_type in ('email', 'phone')),
  constraint client_contacts_normalized_not_blank check (pg_catalog.length(pg_catalog.btrim(normalized_value)) > 0),
  constraint client_contacts_display_not_blank check (pg_catalog.length(pg_catalog.btrim(display_value)) > 0),
  constraint client_contacts_org_id_unique unique (organization_id, id)
);
create index client_contacts_match_idx
  on private.client_contacts (organization_id, contact_type, normalized_value);
create index client_contacts_client_idx
  on private.client_contacts (organization_id, client_id);
create unique index client_contacts_one_primary_per_type_idx
  on private.client_contacts (organization_id, client_id, contact_type)
  where is_primary;

create table core.client_account_links (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  client_id uuid not null,
  user_id uuid not null references auth.users(id) on delete restrict,
  proof_type text not null,
  linked_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  constraint client_account_links_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint client_account_links_proof_check check (proof_type in ('verified_email', 'verified_phone', 'booking_claim', 'staff_approved')),
  constraint client_account_links_revocation_check check (revoked_at is null or revoked_at >= linked_at),
  constraint client_account_links_org_id_unique unique (organization_id, id)
);
create unique index client_account_links_active_user_unique_idx
  on core.client_account_links (organization_id, user_id)
  where revoked_at is null;
create unique index client_account_links_active_client_unique_idx
  on core.client_account_links (organization_id, client_id)
  where revoked_at is null;
create index client_account_links_user_idx on core.client_account_links (user_id, organization_id);

create table private.client_claim_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  client_id uuid not null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  constraint client_claim_tokens_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint client_claim_tokens_org_id_unique unique (organization_id, id),
  constraint client_claim_tokens_expiry_check check (expires_at > created_at),
  constraint client_claim_tokens_hash_not_blank check (pg_catalog.length(pg_catalog.btrim(token_hash)) > 0)
);
create index client_claim_tokens_active_idx
  on private.client_claim_tokens (organization_id, expires_at)
  where consumed_at is null and revoked_at is null;

create table core.client_consents (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  client_id uuid not null,
  purpose text not null,
  channel text not null,
  notice_version text not null,
  consented boolean not null,
  evidence jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default pg_catalog.now(),
  recorded_by_user_id uuid references auth.users(id) on delete set null,
  constraint client_consents_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint client_consents_org_id_unique unique (organization_id, id),
  constraint client_consents_purpose_not_blank check (pg_catalog.length(pg_catalog.btrim(purpose)) > 0),
  constraint client_consents_channel_check check (channel in ('email', 'sms', 'whatsapp', 'phone', 'in_person', 'web', 'other')),
  constraint client_consents_notice_not_blank check (pg_catalog.length(pg_catalog.btrim(notice_version)) > 0),
  constraint client_consents_evidence_object check (pg_catalog.jsonb_typeof(evidence) = 'object')
);
create index client_consents_client_time_idx
  on core.client_consents (organization_id, client_id, recorded_at desc);

create table core.client_merge_events (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  survivor_client_id uuid not null,
  merged_client_id uuid not null,
  merged_by_user_id uuid references auth.users(id) on delete set null,
  reason text,
  occurred_at timestamptz not null default pg_catalog.now(),
  constraint client_merge_events_survivor_fk foreign key (organization_id, survivor_client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint client_merge_events_merged_fk foreign key (organization_id, merged_client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint client_merge_events_org_id_unique unique (organization_id, id),
  constraint client_merge_events_distinct_clients check (survivor_client_id <> merged_client_id)
);
create index client_merge_events_survivor_idx
  on core.client_merge_events (organization_id, survivor_client_id, occurred_at desc);

-- -----------------------------------------------------------------------------
-- 5. Service catalogue, variants, add-ons and branch overrides
-- -----------------------------------------------------------------------------

create table commerce.services (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations(id) on delete restrict,
  name text not null,
  description text,
  category text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint services_org_id_unique unique (organization_id, id),
  constraint services_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  constraint services_name_length check (pg_catalog.char_length(name) <= 160),
  constraint services_description_length check (description is null or pg_catalog.char_length(description) <= 5000)
);
create index services_org_active_idx on commerce.services (organization_id, is_active, name);
create trigger services_set_updated_at before update on commerce.services
for each row execute function core.set_updated_at();

create table commerce.service_variants (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  service_id uuid not null,
  name text not null,
  duration_minutes integer not null,
  price_minor bigint not null,
  currency char(3) not null default 'LKR',
  booking_mode text not null default 'request',
  tax_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint service_variants_service_fk foreign key (organization_id, service_id)
    references commerce.services (organization_id, id) on delete restrict,
  constraint service_variants_org_id_unique unique (organization_id, id),
  constraint service_variants_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  constraint service_variants_duration_check check (duration_minutes between 1 and 1440),
  constraint service_variants_price_check check (price_minor >= 0),
  constraint service_variants_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint service_variants_booking_mode_check check (booking_mode in ('request', 'instant', 'staff_only'))
);
create index service_variants_service_active_idx
  on commerce.service_variants (organization_id, service_id, is_active);
create trigger service_variants_set_updated_at before update on commerce.service_variants
for each row execute function core.set_updated_at();

create table commerce.service_locations (
  organization_id uuid not null,
  location_id uuid not null,
  service_variant_id uuid not null,
  is_enabled boolean not null default true,
  price_minor_override bigint,
  duration_minutes_override integer,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  primary key (organization_id, location_id, service_variant_id),
  constraint service_locations_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint service_locations_variant_fk foreign key (organization_id, service_variant_id)
    references commerce.service_variants (organization_id, id) on delete restrict,
  constraint service_locations_price_check check (price_minor_override is null or price_minor_override >= 0),
  constraint service_locations_duration_check check (duration_minutes_override is null or duration_minutes_override between 1 and 1440)
);
create trigger service_locations_set_updated_at before update on commerce.service_locations
for each row execute function core.set_updated_at();

create table commerce.staff_service_overrides (
  organization_id uuid not null,
  location_id uuid not null,
  staff_profile_id uuid not null,
  service_variant_id uuid not null,
  is_allowed boolean not null default true,
  price_minor_override bigint,
  duration_minutes_override integer,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  primary key (organization_id, location_id, staff_profile_id, service_variant_id),
  constraint staff_service_overrides_staff_location_fk foreign key (organization_id, staff_profile_id, location_id)
    references core.staff_locations (organization_id, staff_profile_id, location_id) on delete restrict,
  constraint staff_service_overrides_variant_location_fk foreign key (organization_id, location_id, service_variant_id)
    references commerce.service_locations (organization_id, location_id, service_variant_id) on delete restrict,
  constraint staff_service_overrides_price_check check (price_minor_override is null or price_minor_override >= 0),
  constraint staff_service_overrides_duration_check check (duration_minutes_override is null or duration_minutes_override between 1 and 1440)
);
create trigger staff_service_overrides_set_updated_at before update on commerce.staff_service_overrides
for each row execute function core.set_updated_at();

create table commerce.service_add_ons (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations(id) on delete restrict,
  name text not null,
  description text,
  duration_minutes integer not null default 0,
  price_minor bigint not null default 0,
  currency char(3) not null default 'LKR',
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint service_add_ons_org_id_unique unique (organization_id, id),
  constraint service_add_ons_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  constraint service_add_ons_duration_check check (duration_minutes between 0 and 1440),
  constraint service_add_ons_price_check check (price_minor >= 0),
  constraint service_add_ons_currency_check check (currency ~ '^[A-Z]{3}$')
);
create trigger service_add_ons_set_updated_at before update on commerce.service_add_ons
for each row execute function core.set_updated_at();

create table commerce.variant_add_ons (
  organization_id uuid not null,
  service_variant_id uuid not null,
  service_add_on_id uuid not null,
  is_required boolean not null default false,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (organization_id, service_variant_id, service_add_on_id),
  constraint variant_add_ons_variant_fk foreign key (organization_id, service_variant_id)
    references commerce.service_variants (organization_id, id) on delete restrict,
  constraint variant_add_ons_add_on_fk foreign key (organization_id, service_add_on_id)
    references commerce.service_add_ons (organization_id, id) on delete restrict
);

-- -----------------------------------------------------------------------------
-- 6. Location hours, closures, staff availability and resources
-- -----------------------------------------------------------------------------

create table ops.location_hours (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  day_of_week smallint not null,
  opens_at time not null,
  closes_at time not null,
  ends_next_day boolean not null default false,
  is_closed boolean not null default false,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint location_hours_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint location_hours_org_id_unique unique (organization_id, id),
  constraint location_hours_day_check check (day_of_week between 0 and 6),
  constraint location_hours_interval_check check (
    is_closed
    or (not ends_next_day and opens_at < closes_at)
    or (ends_next_day and closes_at <= opens_at)
  ),
  constraint location_hours_closed_check check (
    not is_closed or (opens_at = time '00:00' and closes_at = time '00:00' and not ends_next_day)
  )
);
create index location_hours_lookup_idx on ops.location_hours (organization_id, location_id, day_of_week);
create trigger location_hours_set_updated_at before update on ops.location_hours
for each row execute function core.set_updated_at();

create table ops.location_closures (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_at timestamptz not null default pg_catalog.now(),
  constraint location_closures_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint location_closures_org_id_unique unique (organization_id, id),
  constraint location_closures_interval_check check (ends_at > starts_at)
);
create index location_closures_period_idx on ops.location_closures
  using gist (organization_id, location_id, tstzrange(starts_at, ends_at, '[)'));

create table ops.staff_availability (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  staff_profile_id uuid not null,
  day_of_week smallint not null,
  starts_at time not null,
  ends_at time not null,
  ends_next_day boolean not null default false,
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint staff_availability_staff_location_fk foreign key (organization_id, staff_profile_id, location_id)
    references core.staff_locations (organization_id, staff_profile_id, location_id) on delete restrict,
  constraint staff_availability_org_id_unique unique (organization_id, id),
  constraint staff_availability_day_check check (day_of_week between 0 and 6),
  constraint staff_availability_interval_check check (
    (not ends_next_day and starts_at < ends_at)
    or (ends_next_day and ends_at <= starts_at)
  ),
  constraint staff_availability_effective_check check (effective_to is null or effective_to >= effective_from)
);
create index staff_availability_lookup_idx on ops.staff_availability
  (organization_id, location_id, staff_profile_id, day_of_week, effective_from, effective_to);
create trigger staff_availability_set_updated_at before update on ops.staff_availability
for each row execute function core.set_updated_at();

create table ops.staff_exceptions (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  staff_profile_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  exception_type text not null,
  reason text,
  created_at timestamptz not null default pg_catalog.now(),
  constraint staff_exceptions_staff_location_fk foreign key (organization_id, staff_profile_id, location_id)
    references core.staff_locations (organization_id, staff_profile_id, location_id) on delete restrict,
  constraint staff_exceptions_org_id_unique unique (organization_id, id),
  constraint staff_exceptions_interval_check check (ends_at > starts_at),
  constraint staff_exceptions_type_check check (exception_type in ('unavailable', 'available'))
);
create index staff_exceptions_period_idx on ops.staff_exceptions
  using gist (organization_id, location_id, staff_profile_id, tstzrange(starts_at, ends_at, '[)'));

create table ops.resources (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  name text not null,
  resource_type text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint resources_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint resources_org_id_unique unique (organization_id, id),
  constraint resources_org_location_id_unique unique (organization_id, location_id, id),
  constraint resources_name_not_blank check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  constraint resources_type_not_blank check (pg_catalog.length(pg_catalog.btrim(resource_type)) > 0)
);
create index resources_location_active_idx on ops.resources (organization_id, location_id, is_active, resource_type);
create trigger resources_set_updated_at before update on ops.resources
for each row execute function core.set_updated_at();

create table ops.service_resource_requirements (
  organization_id uuid not null,
  location_id uuid not null,
  service_variant_id uuid not null,
  resource_type text not null,
  quantity smallint not null default 1,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (organization_id, location_id, service_variant_id, resource_type),
  constraint service_resource_requirements_service_location_fk foreign key (organization_id, location_id, service_variant_id)
    references commerce.service_locations (organization_id, location_id, service_variant_id) on delete restrict,
  constraint service_resource_requirements_quantity_check check (quantity between 1 and 20),
  constraint service_resource_requirements_type_not_blank check (pg_catalog.length(pg_catalog.btrim(resource_type)) > 0)
);

-- -----------------------------------------------------------------------------
-- 7. Versioned booking policies
-- -----------------------------------------------------------------------------

create table ops.booking_policies (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations(id) on delete restrict,
  location_id uuid,
  policy_name text not null default 'default',
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint booking_policies_org_id_unique unique (organization_id, id),
  constraint booking_policies_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint booking_policies_name_not_blank check (pg_catalog.length(pg_catalog.btrim(policy_name)) > 0)
);
create unique index booking_policies_one_active_scope_idx
  on ops.booking_policies (organization_id, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where is_active;
create trigger booking_policies_set_updated_at before update on ops.booking_policies
for each row execute function core.set_updated_at();

create table ops.booking_policy_versions (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  booking_policy_id uuid not null,
  version_number integer not null,
  min_lead_minutes integer not null default 0,
  max_advance_days integer not null default 90,
  cancellation_cutoff_minutes integer not null default 0,
  confirmation_mode text not null default 'manual',
  deposit_required boolean not null default false,
  deposit_amount_minor bigint,
  deposit_currency char(3) not null default 'LKR',
  policy_snapshot jsonb not null default '{}'::jsonb,
  effective_from timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  created_by_user_id uuid references auth.users(id) on delete set null,
  constraint booking_policy_versions_policy_fk foreign key (organization_id, booking_policy_id)
    references ops.booking_policies (organization_id, id) on delete restrict,
  constraint booking_policy_versions_org_id_unique unique (organization_id, id),
  constraint booking_policy_versions_number_unique unique (organization_id, booking_policy_id, version_number),
  constraint booking_policy_versions_min_lead_check check (min_lead_minutes >= 0),
  constraint booking_policy_versions_horizon_check check (max_advance_days between 1 and 730),
  constraint booking_policy_versions_cutoff_check check (cancellation_cutoff_minutes >= 0),
  constraint booking_policy_versions_confirmation_check check (confirmation_mode in ('manual', 'automatic')),
  constraint booking_policy_versions_deposit_check check (
    (deposit_required and deposit_amount_minor is not null and deposit_amount_minor >= 0)
    or (not deposit_required and deposit_amount_minor is null)
  ),
  constraint booking_policy_versions_currency_check check (deposit_currency ~ '^[A-Z]{3}$'),
  constraint booking_policy_versions_snapshot_object check (pg_catalog.jsonb_typeof(policy_snapshot) = 'object')
);
create index booking_policy_versions_effective_idx on ops.booking_policy_versions
  (organization_id, booking_policy_id, effective_from desc);

-- -----------------------------------------------------------------------------
-- 8. Booking requests, participants, appointments and immutable snapshots
-- -----------------------------------------------------------------------------

create table ops.booking_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  client_id uuid,
  requested_start_at timestamptz not null,
  requested_end_at timestamptz not null,
  status text not null default 'submitted',
  source text not null default 'salon_link',
  source_reference text,
  customer_message text,
  policy_version_id uuid,
  request_key text,
  submitted_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz,
  decided_at timestamptz,
  decided_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint booking_requests_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint booking_requests_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint booking_requests_policy_fk foreign key (organization_id, policy_version_id)
    references ops.booking_policy_versions (organization_id, id) on delete restrict,
  constraint booking_requests_org_id_unique unique (organization_id, id),
  constraint booking_requests_org_id_location_unique unique (organization_id, id, location_id),
  constraint booking_requests_interval_check check (requested_end_at > requested_start_at),
  constraint booking_requests_status_check check (status in ('submitted', 'accepted', 'declined', 'withdrawn', 'expired')),
  constraint booking_requests_source_check check (source in ('discover', 'salon_link', 'owner_entry', 'team_entry', 'walk_in', 'import')),
  constraint booking_requests_request_key_not_blank check (request_key is null or pg_catalog.length(pg_catalog.btrim(request_key)) > 0),
  constraint booking_requests_expiry_check check (expires_at is null or expires_at > submitted_at)
);
create unique index booking_requests_source_key_unique_idx
  on ops.booking_requests (organization_id, request_key) where request_key is not null;
create index booking_requests_inbox_idx
  on ops.booking_requests (organization_id, location_id, status, submitted_at desc);
create index booking_requests_future_idx
  on ops.booking_requests (organization_id, location_id, requested_start_at);
create trigger booking_requests_set_updated_at before update on ops.booking_requests
for each row execute function core.set_updated_at();

-- Requester, payer and service recipient are distinct roles. Guest contact data
-- is held separately in private.booking_participant_contacts.
create table ops.booking_request_participants (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  booking_request_id uuid not null,
  client_id uuid,
  participant_role text not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint booking_request_participants_request_fk foreign key (organization_id, booking_request_id)
    references ops.booking_requests (organization_id, id) on delete restrict,
  constraint booking_request_participants_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint booking_request_participants_org_id_unique unique (organization_id, id),
  constraint booking_request_participants_role_check check (participant_role in ('requester', 'payer', 'service_recipient'))
);
create index booking_request_participants_request_idx
  on ops.booking_request_participants (organization_id, booking_request_id);

create table private.booking_participant_contacts (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  participant_id uuid not null,
  display_name text,
  email text,
  phone text,
  created_at timestamptz not null default pg_catalog.now(),
  constraint booking_participant_contacts_participant_fk foreign key (organization_id, participant_id)
    references ops.booking_request_participants (organization_id, id) on delete restrict,
  constraint booking_participant_contacts_org_id_unique unique (organization_id, id),
  constraint booking_participant_contacts_name_length check (display_name is null or pg_catalog.char_length(display_name) <= 160)
);

create table ops.appointments (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  booking_request_id uuid,
  primary_client_id uuid,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'held',
  payment_status text not null default 'not_required',
  source text not null default 'salon_link',
  held_until timestamptz,
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  completed_at timestamptz,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint appointments_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint appointments_request_fk foreign key (organization_id, booking_request_id, location_id)
    references ops.booking_requests (organization_id, id, location_id) on delete restrict,
  constraint appointments_client_fk foreign key (organization_id, primary_client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint appointments_org_id_unique unique (organization_id, id),
  constraint appointments_org_id_location_unique unique (organization_id, id, location_id),
  constraint appointments_request_once_unique unique (organization_id, booking_request_id),
  constraint appointments_interval_check check (ends_at > starts_at),
  constraint appointments_status_check check (status in ('held', 'confirmed', 'checked_in', 'in_service', 'completed', 'cancelled', 'no_show', 'expired')),
  constraint appointments_payment_status_check check (payment_status in ('not_required', 'pending', 'partially_paid', 'paid', 'failed', 'refunded', 'review_required')),
  constraint appointments_source_check check (source in ('discover', 'salon_link', 'owner_entry', 'team_entry', 'walk_in', 'import')),
  constraint appointments_hold_check check (status <> 'held' or held_until is not null)
);
create index appointments_calendar_idx on ops.appointments
  (organization_id, location_id, starts_at) where status not in ('cancelled', 'no_show', 'expired');
create index appointments_client_idx on ops.appointments
  (organization_id, primary_client_id, starts_at desc) where primary_client_id is not null;
create trigger appointments_set_updated_at before update on ops.appointments
for each row execute function core.set_updated_at();

create table ops.appointment_participants (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  appointment_id uuid not null,
  client_id uuid,
  participant_role text not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint appointment_participants_appointment_fk foreign key (organization_id, appointment_id)
    references ops.appointments (organization_id, id) on delete restrict,
  constraint appointment_participants_client_fk foreign key (organization_id, client_id)
    references core.clients (organization_id, id) on delete restrict,
  constraint appointment_participants_org_id_unique unique (organization_id, id),
  constraint appointment_participants_role_check check (participant_role in ('requester', 'payer', 'service_recipient'))
);
create index appointment_participants_appointment_idx
  on ops.appointment_participants (organization_id, appointment_id);

create table private.appointment_participant_contacts (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  participant_id uuid not null,
  display_name text,
  email text,
  phone text,
  created_at timestamptz not null default pg_catalog.now(),
  constraint appointment_participant_contacts_participant_fk foreign key (organization_id, participant_id)
    references ops.appointment_participants (organization_id, id) on delete restrict,
  constraint appointment_participant_contacts_org_id_unique unique (organization_id, id)
);

-- Delegation is limited to a specific appointment, purpose and expiry. It never
-- grants access to the client's wider CRM history.
create table ops.client_delegated_grants (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  appointment_id uuid not null,
  granted_to_user_id uuid not null references auth.users(id) on delete restrict,
  permission_scope text not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint client_delegated_grants_appointment_fk foreign key (organization_id, appointment_id)
    references ops.appointments (organization_id, id) on delete restrict,
  constraint client_delegated_grants_org_id_unique unique (organization_id, id),
  constraint client_delegated_grants_scope_check check (permission_scope in ('booking_read', 'receipt_read')),
  constraint client_delegated_grants_expiry_check check (expires_at > created_at),
  constraint client_delegated_grants_revocation_check check (revoked_at is null or revoked_at >= created_at)
);
create index client_delegated_grants_user_idx
  on ops.client_delegated_grants (granted_to_user_id, expires_at) where revoked_at is null;
create unique index client_delegated_grants_active_unique_idx
  on ops.client_delegated_grants (organization_id, appointment_id, granted_to_user_id, permission_scope)
  where revoked_at is null;

create table ops.appointment_items (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  appointment_id uuid not null,
  location_id uuid not null,
  service_variant_id uuid,
  item_name_snapshot text not null,
  duration_minutes integer not null,
  price_minor bigint not null,
  currency char(3) not null default 'LKR',
  tax_snapshot jsonb not null default '{}'::jsonb,
  sort_order smallint not null default 1,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint appointment_items_appointment_fk foreign key (organization_id, appointment_id, location_id)
    references ops.appointments (organization_id, id, location_id) on delete restrict,
  constraint appointment_items_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint appointment_items_variant_location_fk foreign key (organization_id, location_id, service_variant_id)
    references commerce.service_locations (organization_id, location_id, service_variant_id) on delete restrict,
  constraint appointment_items_org_id_unique unique (organization_id, id),
  constraint appointment_items_org_id_location_unique unique (organization_id, id, location_id),
  constraint appointment_items_name_not_blank check (pg_catalog.length(pg_catalog.btrim(item_name_snapshot)) > 0),
  constraint appointment_items_duration_check check (duration_minutes between 1 and 1440),
  constraint appointment_items_price_check check (price_minor >= 0),
  constraint appointment_items_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint appointment_items_tax_object check (pg_catalog.jsonb_typeof(tax_snapshot) = 'object'),
  constraint appointment_items_sort_check check (sort_order > 0),
  constraint appointment_items_interval_check check (ends_at > starts_at)
);
create index appointment_items_appointment_idx on ops.appointment_items
  (organization_id, appointment_id, sort_order);

create table ops.appointment_item_add_ons (
  organization_id uuid not null,
  id uuid primary key default extensions.gen_random_uuid(),
  appointment_item_id uuid not null,
  service_add_on_id uuid,
  add_on_name_snapshot text not null,
  duration_minutes integer not null,
  price_minor bigint not null,
  currency char(3) not null default 'LKR',
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint appointment_item_add_ons_org_id_unique unique (organization_id, id),
  constraint appointment_item_add_ons_item_fk foreign key (organization_id, appointment_item_id)
    references ops.appointment_items (organization_id, id) on delete restrict,
  constraint appointment_item_add_ons_catalogue_fk foreign key (organization_id, service_add_on_id)
    references commerce.service_add_ons (organization_id, id) on delete restrict,
  constraint appointment_item_add_ons_duration_check check (duration_minutes between 0 and 1440),
  constraint appointment_item_add_ons_price_check check (price_minor >= 0),
  constraint appointment_item_add_ons_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint appointment_item_add_ons_interval_check check (ends_at >= starts_at)
);

create table ops.appointment_status_history (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  appointment_id uuid not null,
  from_status text,
  to_status text not null,
  reason text,
  actor_user_id uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default pg_catalog.now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint appointment_status_history_appointment_fk foreign key (organization_id, appointment_id)
    references ops.appointments (organization_id, id) on delete restrict,
  constraint appointment_status_history_org_id_unique unique (organization_id, id),
  constraint appointment_status_history_to_check check (to_status in ('held', 'confirmed', 'checked_in', 'in_service', 'completed', 'cancelled', 'no_show', 'expired')),
  constraint appointment_status_history_from_check check (from_status is null or from_status in ('held', 'confirmed', 'checked_in', 'in_service', 'completed', 'cancelled', 'no_show', 'expired')),
  constraint appointment_status_history_metadata_object check (pg_catalog.jsonb_typeof(metadata) = 'object')
);
create index appointment_status_history_time_idx
  on ops.appointment_status_history (organization_id, appointment_id, occurred_at);

-- -----------------------------------------------------------------------------
-- 9. Concrete staff/resource allocations and cross-branch conflict protection
-- -----------------------------------------------------------------------------

create table ops.appointment_allocations (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  appointment_id uuid not null,
  appointment_item_id uuid not null,
  location_id uuid not null,
  allocation_kind text not null,
  staff_profile_id uuid,
  resource_id uuid,
  subject_id uuid generated always as (coalesce(staff_profile_id, resource_id)) stored,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_blocking boolean not null default true,
  released_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  constraint appointment_allocations_appointment_fk foreign key (organization_id, appointment_id, location_id)
    references ops.appointments (organization_id, id, location_id) on delete restrict,
  constraint appointment_allocations_item_fk foreign key (organization_id, appointment_item_id, location_id)
    references ops.appointment_items (organization_id, id, location_id) on delete restrict,
  constraint appointment_allocations_location_fk foreign key (organization_id, location_id)
    references core.locations (organization_id, id) on delete restrict,
  constraint appointment_allocations_staff_location_fk foreign key (organization_id, staff_profile_id, location_id)
    references core.staff_locations (organization_id, staff_profile_id, location_id) on delete restrict,
  constraint appointment_allocations_resource_fk foreign key (organization_id, location_id, resource_id)
    references ops.resources (organization_id, location_id, id) on delete restrict,
  constraint appointment_allocations_org_id_unique unique (organization_id, id),
  constraint appointment_allocations_kind_check check (allocation_kind in ('staff', 'resource')),
  constraint appointment_allocations_subject_check check (
    (allocation_kind = 'staff' and staff_profile_id is not null and resource_id is null)
    or (allocation_kind = 'resource' and resource_id is not null and staff_profile_id is null)
  ),
  constraint appointment_allocations_interval_check check (ends_at > starts_at),
  constraint appointment_allocations_release_check check (
    (is_blocking and released_at is null) or (not is_blocking and released_at is not null)
  )
);

-- Staff identity is organization-wide, not branch-specific. This prevents a
-- staff member from being double-booked at two branches of the same tenant.
alter table ops.appointment_allocations
  add constraint appointment_allocations_no_overlap
  exclude using gist (
    organization_id with =,
    allocation_kind with =,
    subject_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (is_blocking);

create index appointment_allocations_appointment_idx
  on ops.appointment_allocations (organization_id, appointment_id);
create index appointment_allocations_location_period_idx
  on ops.appointment_allocations using gist
  (organization_id, location_id, tstzrange(starts_at, ends_at, '[)'));

-- -----------------------------------------------------------------------------
-- 10. Idempotent operation records and transactional outbox
-- -----------------------------------------------------------------------------

create table ops.operation_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references core.organizations(id) on delete restrict,
  operation_scope text not null,
  operation_key text not null,
  request_hash text not null,
  status text not null default 'started',
  result jsonb,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  completed_at timestamptz,
  constraint operation_requests_scope_not_blank check (pg_catalog.length(pg_catalog.btrim(operation_scope)) > 0),
  constraint operation_requests_key_not_blank check (pg_catalog.length(pg_catalog.btrim(operation_key)) > 0),
  constraint operation_requests_hash_not_blank check (pg_catalog.length(pg_catalog.btrim(request_hash)) > 0),
  constraint operation_requests_status_check check (status in ('started', 'completed', 'failed')),
  constraint operation_requests_result_object check (result is null or pg_catalog.jsonb_typeof(result) = 'object'),
  constraint operation_requests_org_scope_key_unique unique (organization_id, operation_scope, operation_key)
);
create index operation_requests_created_idx on ops.operation_requests
  (organization_id, created_at desc);

create table ops.outbox_events (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid references core.organizations(id) on delete restrict,
  event_type text not null,
  aggregate_type text not null,
  aggregate_id uuid not null,
  payload_version smallint not null default 1,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  available_at timestamptz not null default pg_catalog.now(),
  attempts integer not null default 0,
  locked_at timestamptz,
  processed_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default pg_catalog.now(),
  constraint outbox_event_type_not_blank check (pg_catalog.length(pg_catalog.btrim(event_type)) > 0),
  constraint outbox_aggregate_type_not_blank check (pg_catalog.length(pg_catalog.btrim(aggregate_type)) > 0),
  constraint outbox_payload_object check (pg_catalog.jsonb_typeof(payload) = 'object'),
  constraint outbox_status_check check (status in ('pending', 'processing', 'processed', 'failed')),
  constraint outbox_attempts_check check (attempts >= 0),
  constraint outbox_payload_version_check check (payload_version > 0)
);
create index outbox_pending_idx on ops.outbox_events (available_at, created_at)
  where status in ('pending', 'failed');
create index outbox_org_time_idx on ops.outbox_events (organization_id, created_at desc);

-- -----------------------------------------------------------------------------
-- 11. Permission catalogue additions
-- -----------------------------------------------------------------------------

insert into core.permissions (code, description) values
  ('clients.read', 'View tenant client records'),
  ('clients.manage', 'Create and manage tenant client records'),
  ('services.read', 'View the service catalogue'),
  ('services.manage', 'Manage services, variants and add-ons'),
  ('schedule.read', 'View authorized branch schedules'),
  ('schedule.manage', 'Manage location and staff availability'),
  ('resources.manage', 'Manage branch booking resources'),
  ('booking_requests.read', 'View and decide booking requests'),
  ('appointments.read', 'View appointments in authorized branch scope'),
  ('appointments.manage', 'Create and manage appointments')
on conflict (code) do nothing;

insert into core.role_permissions (role_id, permission_id)
select r.id, p.id
from core.roles r
join core.permissions p on p.code in (
  'clients.read', 'clients.manage', 'services.read', 'services.manage',
  'schedule.read', 'schedule.manage', 'resources.manage',
  'booking_requests.read', 'appointments.read', 'appointments.manage'
)
where r.code = 'owner'
on conflict do nothing;

insert into core.role_permissions (role_id, permission_id)
select r.id, p.id
from core.roles r
join core.permissions p on p.code in (
  'clients.read', 'clients.manage', 'services.read', 'services.manage',
  'schedule.read', 'schedule.manage', 'resources.manage',
  'booking_requests.read', 'appointments.read', 'appointments.manage'
)
where r.code = 'manager'
on conflict do nothing;

insert into core.role_permissions (role_id, permission_id)
select r.id, p.id
from core.roles r
join core.permissions p on p.code in ('services.read', 'schedule.read', 'appointments.read')
where r.code = 'team_member'
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 12. Row-level security
-- -----------------------------------------------------------------------------

alter table core.business_categories enable row level security;
alter table core.organization_categories enable row level security;
alter table core.staff_profiles enable row level security;
alter table core.staff_locations enable row level security;
alter table core.clients enable row level security;
alter table core.client_account_links enable row level security;
alter table core.client_consents enable row level security;
alter table core.client_merge_events enable row level security;
alter table private.client_contacts enable row level security;
alter table private.client_claim_tokens enable row level security;

alter table commerce.services enable row level security;
alter table commerce.service_variants enable row level security;
alter table commerce.service_locations enable row level security;
alter table commerce.staff_service_overrides enable row level security;
alter table commerce.service_add_ons enable row level security;
alter table commerce.variant_add_ons enable row level security;

alter table ops.location_hours enable row level security;
alter table ops.location_closures enable row level security;
alter table ops.staff_availability enable row level security;
alter table ops.staff_exceptions enable row level security;
alter table ops.resources enable row level security;
alter table ops.service_resource_requirements enable row level security;
alter table ops.booking_policies enable row level security;
alter table ops.booking_policy_versions enable row level security;
alter table ops.booking_requests enable row level security;
alter table ops.booking_request_participants enable row level security;
alter table private.booking_participant_contacts enable row level security;
alter table ops.appointments enable row level security;
alter table ops.appointment_participants enable row level security;
alter table ops.client_delegated_grants enable row level security;
alter table private.appointment_participant_contacts enable row level security;
alter table ops.appointment_items enable row level security;
alter table ops.appointment_item_add_ons enable row level security;
alter table ops.appointment_status_history enable row level security;
alter table ops.appointment_allocations enable row level security;
alter table ops.operation_requests enable row level security;
alter table ops.outbox_events enable row level security;

create policy business_categories_select_active on core.business_categories
for select to authenticated using (is_active);

create policy organization_categories_select_member on core.organization_categories
for select to authenticated using (core.is_active_org_member(organization_id));

create policy staff_profiles_select_authorized on core.staff_profiles
for select to authenticated using (
  exists (
    select 1 from core.staff_locations sl
    where sl.organization_id = staff_profiles.organization_id
      and sl.staff_profile_id = staff_profiles.id
      and sl.is_active
      and core.has_org_permission(sl.organization_id, 'schedule.read', sl.location_id)
  )
);
create policy staff_locations_select_authorized on core.staff_locations
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);

create policy clients_select_authorized on core.clients
for select to authenticated using (
  core.has_org_permission(organization_id, 'clients.read')
);
create policy client_account_links_select_self_or_manager on core.client_account_links
for select to authenticated using (
  user_id = (select auth.uid())
  or core.has_org_permission(organization_id, 'clients.read')
);
create policy client_consents_select_authorized on core.client_consents
for select to authenticated using (
  core.has_org_permission(organization_id, 'clients.read')
);
create policy client_merge_events_select_authorized on core.client_merge_events
for select to authenticated using (
  core.has_org_permission(organization_id, 'clients.read')
);
create policy client_delegated_grants_select_recipient on ops.client_delegated_grants
for select to authenticated using (
  granted_to_user_id = (select auth.uid()) and revoked_at is null and expires_at > pg_catalog.now()
);

create policy services_select_authorized on commerce.services
for select to authenticated using (
  exists (
    select 1 from commerce.service_variants sv
    join commerce.service_locations sl
      on sl.organization_id = sv.organization_id and sl.service_variant_id = sv.id
    where sv.organization_id = services.organization_id
      and sv.service_id = services.id and sl.is_enabled
      and core.has_org_permission(sl.organization_id, 'services.read', sl.location_id)
  )
);
create policy service_variants_select_authorized on commerce.service_variants
for select to authenticated using (
  exists (
    select 1 from commerce.service_locations sl
    where sl.organization_id = service_variants.organization_id
      and sl.service_variant_id = service_variants.id and sl.is_enabled
      and core.has_org_permission(sl.organization_id, 'services.read', sl.location_id)
  )
);
create policy service_locations_select_authorized on commerce.service_locations
for select to authenticated using (
  core.has_org_permission(organization_id, 'services.read', location_id)
);
create policy staff_service_overrides_select_authorized on commerce.staff_service_overrides
for select to authenticated using (
  core.has_org_permission(organization_id, 'services.read', location_id)
);
create policy service_add_ons_select_authorized on commerce.service_add_ons
for select to authenticated using (
  exists (
    select 1 from commerce.variant_add_ons va
    join commerce.service_locations sl
      on sl.organization_id = va.organization_id and sl.service_variant_id = va.service_variant_id
    where va.organization_id = service_add_ons.organization_id
      and va.service_add_on_id = service_add_ons.id and sl.is_enabled
      and core.has_org_permission(sl.organization_id, 'services.read', sl.location_id)
  )
);
create policy variant_add_ons_select_authorized on commerce.variant_add_ons
for select to authenticated using (
  exists (
    select 1 from commerce.service_locations sl
    where sl.organization_id = variant_add_ons.organization_id
      and sl.service_variant_id = variant_add_ons.service_variant_id and sl.is_enabled
      and core.has_org_permission(sl.organization_id, 'services.read', sl.location_id)
  )
);

create policy location_hours_select_authorized on ops.location_hours
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);
create policy location_closures_select_authorized on ops.location_closures
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);
create policy staff_availability_select_authorized on ops.staff_availability
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);
create policy staff_exceptions_select_authorized on ops.staff_exceptions
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);
create policy resources_select_authorized on ops.resources
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);
create policy service_resource_requirements_select_authorized on ops.service_resource_requirements
for select to authenticated using (
  core.has_org_permission(organization_id, 'schedule.read', location_id)
);
create policy booking_policies_select_authorized on ops.booking_policies
for select to authenticated using (
  (location_id is not null and core.has_org_permission(organization_id, 'schedule.read', location_id))
  or (location_id is null and (
    core.has_org_permission(organization_id, 'schedule.read')
    or exists (
      select 1 from core.locations l
      where l.organization_id = booking_policies.organization_id
        and l.status = 'active'
        and core.has_org_permission(l.organization_id, 'schedule.read', l.id)
    )
  ))
);
create policy booking_policy_versions_select_authorized on ops.booking_policy_versions
for select to authenticated using (
  exists (
    select 1 from ops.booking_policies bp
    where bp.organization_id = booking_policy_versions.organization_id
      and bp.id = booking_policy_versions.booking_policy_id
      and ((bp.location_id is null and (
          core.has_org_permission(bp.organization_id, 'schedule.read')
          or exists (select 1 from core.locations l where l.organization_id = bp.organization_id
            and l.status = 'active' and core.has_org_permission(l.organization_id, 'schedule.read', l.id))
        )) or (bp.location_id is not null and core.has_org_permission(bp.organization_id, 'schedule.read', bp.location_id)))
  )
);

create policy booking_requests_select_authorized on ops.booking_requests
for select to authenticated using (
  core.has_org_permission(organization_id, 'booking_requests.read', location_id)
  or exists (
    select 1 from core.client_account_links l
    where l.organization_id = booking_requests.organization_id
      and l.client_id = booking_requests.client_id
      and l.user_id = (select auth.uid()) and l.revoked_at is null
  )
);
create policy booking_request_participants_select_authorized on ops.booking_request_participants
for select to authenticated using (
  exists (
    select 1 from ops.booking_requests br
    where br.organization_id = booking_request_participants.organization_id
      and br.id = booking_request_participants.booking_request_id
      and core.has_org_permission(br.organization_id, 'booking_requests.read', br.location_id)
  )
);

create policy appointments_select_authorized on ops.appointments
for select to authenticated using (
  core.has_org_permission(organization_id, 'appointments.read', location_id)
  or exists (
    select 1 from core.client_account_links l
    where l.organization_id = appointments.organization_id
      and l.client_id = appointments.primary_client_id
      and l.user_id = (select auth.uid()) and l.revoked_at is null
  )
  or exists (
    select 1 from ops.client_delegated_grants dg
    where dg.organization_id = appointments.organization_id
      and dg.appointment_id = appointments.id
      and dg.granted_to_user_id = (select auth.uid())
      and dg.permission_scope = 'booking_read' and dg.revoked_at is null
      and dg.expires_at > pg_catalog.now()
  )
);
create policy appointment_participants_select_authorized on ops.appointment_participants
for select to authenticated using (
  exists (
    select 1 from ops.appointments a
    where a.organization_id = appointment_participants.organization_id
      and a.id = appointment_participants.appointment_id
      and core.has_org_permission(a.organization_id, 'appointments.read', a.location_id)
  )
  or exists (
    select 1 from core.client_account_links l
    where l.organization_id = appointment_participants.organization_id
      and l.client_id = appointment_participants.client_id
      and l.user_id = (select auth.uid()) and l.revoked_at is null
  )
);
create policy appointment_items_select_authorized on ops.appointment_items
for select to authenticated using (
  core.has_org_permission(organization_id, 'appointments.read', location_id)
  or exists (
    select 1 from ops.appointments a
    join core.client_account_links l
      on l.organization_id = a.organization_id and l.client_id = a.primary_client_id
    where a.organization_id = appointment_items.organization_id
      and a.id = appointment_items.appointment_id
      and l.user_id = (select auth.uid()) and l.revoked_at is null
  )
  or exists (
    select 1 from ops.client_delegated_grants dg
    where dg.organization_id = appointment_items.organization_id
      and dg.appointment_id = appointment_items.appointment_id
      and dg.granted_to_user_id = (select auth.uid())
      and dg.permission_scope = 'booking_read' and dg.revoked_at is null
      and dg.expires_at > pg_catalog.now()
  )
);
create policy appointment_item_add_ons_select_authorized on ops.appointment_item_add_ons
for select to authenticated using (
  exists (
    select 1 from ops.appointment_items ai
    where ai.organization_id = appointment_item_add_ons.organization_id
      and ai.id = appointment_item_add_ons.appointment_item_id
      and core.has_org_permission(ai.organization_id, 'appointments.read', ai.location_id)
  )
);
create policy appointment_status_history_select_authorized on ops.appointment_status_history
for select to authenticated using (
  exists (
    select 1 from ops.appointments a
    where a.organization_id = appointment_status_history.organization_id
      and a.id = appointment_status_history.appointment_id
      and core.has_org_permission(a.organization_id, 'appointments.read', a.location_id)
  )
);
create policy appointment_allocations_select_authorized on ops.appointment_allocations
for select to authenticated using (
  core.has_org_permission(organization_id, 'appointments.read', location_id)
);

-- No direct client policies for private contacts, claim tokens, idempotency or
-- outbox records. Those are accessed only by tightly scoped server workflows.

-- -----------------------------------------------------------------------------
-- 13. Explicit grants: default deny, server-managed writes
-- -----------------------------------------------------------------------------

revoke all on all tables in schema ops from anon, authenticated;
revoke all on all tables in schema commerce from anon, authenticated;
-- Do not blanket-revoke schema core: Migration 001 already grants narrowly
-- scoped access to profiles, organizations, locations and membership catalogues.
revoke all on core.business_categories, core.organization_categories,
  core.staff_profiles, core.staff_locations, core.clients,
  core.client_account_links, core.client_consents, core.client_merge_events
  from anon, authenticated;
revoke all on private.client_contacts, private.client_claim_tokens,
  private.booking_participant_contacts, private.appointment_participant_contacts
  from anon, authenticated;

-- Authenticated users receive only reads that are additionally filtered by RLS.
grant select on core.business_categories, core.organization_categories,
  core.staff_profiles, core.staff_locations, core.clients,
  core.client_account_links, core.client_consents, core.client_merge_events to authenticated;
grant select on commerce.services, commerce.service_variants,
  commerce.service_locations, commerce.staff_service_overrides,
  commerce.service_add_ons, commerce.variant_add_ons to authenticated;
grant select on ops.location_hours, ops.location_closures,
  ops.staff_availability, ops.staff_exceptions, ops.resources,
  ops.service_resource_requirements, ops.booking_policies,
  ops.booking_policy_versions, ops.booking_requests,
  ops.booking_request_participants, ops.appointments,
  ops.appointment_participants, ops.client_delegated_grants, ops.appointment_items,
  ops.appointment_item_add_ons, ops.appointment_status_history,
  ops.appointment_allocations to authenticated;

-- Server-side workflows own all inserts/updates/deletes in these modules.
grant usage on schema commerce, ops to authenticated, service_role;
grant usage on schema core, private to authenticated, service_role;
grant all on all tables in schema commerce to service_role;
grant all on all tables in schema ops to service_role;
grant all on all tables in schema core to service_role;
grant all on all tables in schema private to service_role;

commit;
