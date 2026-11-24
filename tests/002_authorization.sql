\set ON_ERROR_STOP on
begin;

create function pg_temp.fixture_id(n integer) returns uuid
language sql immutable as $$
  select ('a2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

create function pg_temp.assert_check(passed boolean, label text) returns void
language plpgsql as $$
begin
  if passed is distinct from true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS %', label;
end;
$$;

insert into auth.users (id, email) values
  (pg_temp.fixture_id(1), 'velouvi-owner-a@example.test'),
  (pg_temp.fixture_id(2), 'velouvi-manager-a@example.test'),
  (pg_temp.fixture_id(3), 'velouvi-owner-b@example.test');

insert into core.organizations (id, name, slug) values
  (pg_temp.fixture_id(11), 'Test Organization A', 'velouvi-authorization-test-a'),
  (pg_temp.fixture_id(12), 'Test Organization B', 'velouvi-authorization-test-b');

insert into core.locations (id, organization_id, name) values
  (pg_temp.fixture_id(21), pg_temp.fixture_id(11), 'Branch A1'),
  (pg_temp.fixture_id(22), pg_temp.fixture_id(11), 'Branch A2'),
  (pg_temp.fixture_id(23), pg_temp.fixture_id(12), 'Branch B1');

insert into core.memberships (id, organization_id, user_id, status, activated_at) values
  (pg_temp.fixture_id(31), pg_temp.fixture_id(11), pg_temp.fixture_id(1), 'active', now()),
  (pg_temp.fixture_id(32), pg_temp.fixture_id(11), pg_temp.fixture_id(2), 'active', now()),
  (pg_temp.fixture_id(33), pg_temp.fixture_id(12), pg_temp.fixture_id(3), 'active', now());

insert into core.role_assignments (organization_id, membership_id, role_id, location_id)
select pg_temp.fixture_id(f.org), pg_temp.fixture_id(f.member), r.id,
       case when f.loc is not null then pg_temp.fixture_id(f.loc) end
from (values (11,31,'owner',null), (11,32,'manager',21), (12,33,'owner',null))
  f(org, member, role, loc)
join core.roles r on r.code = f.role;

insert into core.staff_profiles (organization_id, id, display_name)
select pg_temp.fixture_id(f.org), pg_temp.fixture_id(f.staff), 'Staff ' || f.staff
from (values (11,41), (11,42), (12,43)) f(org,staff);
insert into core.staff_locations (organization_id, staff_profile_id, location_id)
select pg_temp.fixture_id(f.org), pg_temp.fixture_id(f.staff), pg_temp.fixture_id(f.location)
from (values (11,41,21), (11,42,22), (12,43,23)) f(org,staff,location);
insert into core.clients (organization_id, id, display_name) values
  (pg_temp.fixture_id(11), pg_temp.fixture_id(51), 'Client A'),
  (pg_temp.fixture_id(12), pg_temp.fixture_id(52), 'Client B');
insert into commerce.services (organization_id,id,name)
select pg_temp.fixture_id(f.org), pg_temp.fixture_id(f.service), 'Service ' || f.service
from (values (11,61), (11,62), (12,63)) f(org,service);
insert into commerce.service_variants (organization_id,id,service_id,name,duration_minutes,price_minor)
select pg_temp.fixture_id(f.org), pg_temp.fixture_id(f.variant), pg_temp.fixture_id(f.service),
       'Standard',30,200000
from (values (11,71,61), (11,72,62), (12,73,63)) f(org,variant,service);
insert into commerce.service_locations (organization_id,location_id,service_variant_id)
select pg_temp.fixture_id(f.org), pg_temp.fixture_id(f.loc), pg_temp.fixture_id(f.variant)
from (values (11,21,71), (11,22,72), (12,23,73)) f(org,loc,variant);

select pg_temp.assert_check(
  (select count(*) from core.memberships
   where user_id in (pg_temp.fixture_id(1), pg_temp.fixture_id(2), pg_temp.fixture_id(3)) and status='active') = 3
  and (select count(*) from core.role_assignments
       where membership_id in (pg_temp.fixture_id(31), pg_temp.fixture_id(32), pg_temp.fixture_id(33))
         and revoked_at is null) = 3,
  'three active fixture members and three role assignments');

create function pg_temp.visibility()
returns bigint[] language sql as $$
  select array[
    (select count(*) from core.organizations where id in (pg_temp.fixture_id(11),pg_temp.fixture_id(12))),
    (select count(*) from core.locations where id in (pg_temp.fixture_id(21),pg_temp.fixture_id(22),pg_temp.fixture_id(23))),
    (select count(*) from core.staff_profiles where id in (pg_temp.fixture_id(41),pg_temp.fixture_id(42),pg_temp.fixture_id(43))),
    (select count(*) from commerce.services where id in (pg_temp.fixture_id(61),pg_temp.fixture_id(62),pg_temp.fixture_id(63))),
    (select count(*) from core.clients where id in (pg_temp.fixture_id(51),pg_temp.fixture_id(52)))
  ]
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', pg_temp.fixture_id(2)::text, true);
select 'Manager A' as actor, pg_temp.visibility() as visible;
select pg_temp.assert_check(pg_temp.visibility() = array[1,1,1,1,0]::bigint[], 'Manager A exact visibility');
select pg_temp.assert_check(
  exists (select from core.locations where id=pg_temp.fixture_id(21))
  and exists (select from core.staff_profiles where id=pg_temp.fixture_id(41))
  and exists (select from commerce.services where id=pg_temp.fixture_id(61))
  and not exists (select from core.organizations where id=pg_temp.fixture_id(12)),
  'manager sees assigned branch records only');

select set_config('request.jwt.claim.sub', pg_temp.fixture_id(1)::text, true);
select 'Owner A' as actor, pg_temp.visibility() as visible;
select pg_temp.assert_check(pg_temp.visibility() = array[1,2,2,2,1]::bigint[], 'Owner A exact visibility');
select pg_temp.assert_check(not exists(select from commerce.services where id=pg_temp.fixture_id(63))
  and not exists(select from core.clients where id=pg_temp.fixture_id(52)), 'Owner A cannot access tenant B');

select set_config('request.jwt.claim.sub', pg_temp.fixture_id(3)::text, true);
select 'Owner B' as actor, pg_temp.visibility() as visible;
select pg_temp.assert_check(pg_temp.visibility() = array[1,1,1,1,1]::bigint[], 'Owner B exact visibility');
select pg_temp.assert_check(exists(select from core.clients where id=pg_temp.fixture_id(52))
  and not exists(select from core.organizations where id=pg_temp.fixture_id(11)), 'Owner B sees only tenant B');
select pg_temp.assert_check(
  not has_table_privilege(current_user,'private.client_contacts','select')
  and not has_table_privilege(current_user,'private.client_claim_tokens','select')
  and not has_table_privilege(current_user,'private.booking_participant_contacts','select')
  and not has_table_privilege(current_user,'ops.operation_requests','select')
  and not has_table_privilege(current_user,'ops.outbox_events','select')
  and not has_table_privilege(current_user,'ops.booking_requests','insert')
  and not has_table_privilege(current_user,'core.clients','insert')
  and not has_table_privilege(current_user,'commerce.services','update'), 'all eight protected access checks');

reset role;
update core.memberships set status='revoked', revoked_at=now() where id=pg_temp.fixture_id(32);
set local role authenticated;
select set_config('request.jwt.claim.sub', pg_temp.fixture_id(2)::text, true);
select pg_temp.assert_check(pg_temp.visibility() = array[0,0,0,0,0]::bigint[], 'revocation removes manager visibility');
reset role;
update core.memberships set status='active', revoked_at=null where id=pg_temp.fixture_id(32);
update core.role_assignments set revoked_at=now() where membership_id=pg_temp.fixture_id(32);
set local role authenticated;
select pg_temp.assert_check(pg_temp.visibility() = array[1,0,0,0,0]::bigint[], 'assignment revocation preserves membership only');
reset role;
select pg_temp.assert_check(
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname in ('core','private','ops','commerce') and c.relkind='r' and not c.relrowsecurity) = 0,
  'RLS enabled across application tables');
rollback;
