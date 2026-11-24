\set ON_ERROR_STOP on
begin;

create function pg_temp.bid(n integer) returns uuid language sql immutable as $$
  select ('a3000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
create function pg_temp.slot(h integer,m integer default 0) returns timestamptz language sql stable as $$
  select (((now() at time zone 'Asia/Colombo')::date+1) + make_time(h,m,0)) at time zone 'Asia/Colombo'
$$;
create function pg_temp.ok(passed boolean,label text) returns void language plpgsql as $$
begin
  if passed is distinct from true then raise exception 'FAIL %',label; end if;
  raise notice 'PASS %',label;
end;
$$;
create function pg_temp.fails(statement text,code text,label text) returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if sqlstate=code then raise notice 'PASS %',label; return; end if;
    raise;
  end;
  raise exception 'FAIL % was allowed',label;
end;
$$;
create function pg_temp.result_id(k text) returns uuid language sql stable as $$
  select current_setting('booking.fixture_'||k)::uuid
$$;

insert into auth.users (id,email) values
  (pg_temp.bid(1),'booking-owner@example.test'),(pg_temp.bid(2),'booking-manager@example.test'),
  (pg_temp.bid(3),'booking-moderator@example.test'),(pg_temp.bid(4),'different-tenant@example.test');
insert into core.organizations(id,name,slug) values
  (pg_temp.bid(10),'Fixture Beauty','booking-fixture-a'),(pg_temp.bid(11),'Another Tenant','booking-fixture-b');
insert into core.locations(id,organization_id,name)
select pg_temp.bid(f.loc),pg_temp.bid(f.org),f.name
from (values (21,10,'A1'),(22,10,'A2'),(23,11,'B1')) f(loc,org,name);
insert into core.memberships(id,organization_id,user_id,status,activated_at)
select pg_temp.bid(f.member),pg_temp.bid(f.org),pg_temp.bid(f.u),'active',now()
from (values(31,10,1),(32,10,2),(34,11,4)) f(member,org,u);
insert into core.role_assignments(organization_id,membership_id,role_id,location_id)
select pg_temp.bid(f.org),pg_temp.bid(f.member),r.id,
  case when f.loc is not null then pg_temp.bid(f.loc) end
from (values(10,31,'owner',null),(10,32,'manager',21),(11,34,'owner',null)) f(org,member,role,loc)
join core.roles r on r.code=f.role;
insert into core.platform_memberships (id,user_id,status)
values (pg_temp.bid(33),pg_temp.bid(3),'active');
insert into core.platform_role_assignments (platform_membership_id,platform_role_id)
select pg_temp.bid(33),id from core.platform_roles where code='operations';

insert into core.staff_profiles(id,organization_id,display_name) values
  (pg_temp.bid(41),pg_temp.bid(10),'First Stylist'),(pg_temp.bid(42),pg_temp.bid(10),'Second Stylist');
insert into core.staff_locations(organization_id,staff_profile_id,location_id)
select pg_temp.bid(10),pg_temp.bid(f.staff),pg_temp.bid(f.loc) from (values(41,21),(41,22),(42,21)) f(staff,loc);
insert into commerce.services(id,organization_id,name)
values (pg_temp.bid(61),pg_temp.bid(10),'Facial'),(pg_temp.bid(62),pg_temp.bid(10),'Consultation');
insert into commerce.service_variants(id,organization_id,service_id,name,duration_minutes,price_minor)
values (pg_temp.bid(71),pg_temp.bid(10),pg_temp.bid(61),'Standard',30,250000),
       (pg_temp.bid(72),pg_temp.bid(10),pg_temp.bid(62),'Standard',30,100000);
insert into commerce.service_locations(organization_id,location_id,service_variant_id)
select pg_temp.bid(10),pg_temp.bid(f.loc),pg_temp.bid(f.variant) from (values(21,71),(21,72),(22,71)) f(loc,variant);
insert into commerce.staff_service_overrides(organization_id,location_id,staff_profile_id,service_variant_id,is_allowed)
values (pg_temp.bid(10),pg_temp.bid(21),pg_temp.bid(42),pg_temp.bid(71),false),
  (pg_temp.bid(10),pg_temp.bid(21),pg_temp.bid(41),pg_temp.bid(72),false);
insert into ops.location_hours(organization_id,location_id,day_of_week,opens_at,closes_at)
select pg_temp.bid(10),pg_temp.bid(loc),dow,'09:00','17:00' from (values(21),(22)) l(loc) cross join generate_series(0,6) dow;
insert into ops.staff_availability(organization_id,location_id,staff_profile_id,day_of_week,starts_at,ends_at)
select sl.organization_id,sl.location_id,sl.staff_profile_id,dow,'09:00','17:00'
from core.staff_locations sl cross join generate_series(0,6) dow where sl.organization_id=pg_temp.bid(10);
insert into ops.resources(id,organization_id,location_id,name,resource_type)
values (pg_temp.bid(81),pg_temp.bid(10),pg_temp.bid(21),'Room A','room');
insert into ops.service_resource_requirements(organization_id,location_id,service_variant_id,resource_type)
select pg_temp.bid(10),pg_temp.bid(21),pg_temp.bid(f.variant),'room' from (values(71),(72)) f(variant);

set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.bid(1)::text,true);
select set_config('booking.fixture_a1',api.save_listing(pg_temp.bid(21),'fixture-a1','Visible Branch A1','Public description')::text,true);
select set_config('booking.fixture_a2',api.save_listing(pg_temp.bid(22),'fixture-a2','Visible Branch A2','Public description')::text,true);
select pg_temp.fails('select api.moderate_listing(pg_temp.result_id(''a1''),true)','42501','owner cannot self-approve listing');
reset role;

set local role anon;
select set_config('request.jwt.claim.sub','',true);
select pg_temp.ok((select count(*) from api.discover_listings('fixture-a1'))=0,'draft listing is private');
select pg_temp.fails('select * from marketplace.listings','42501','anonymous cannot access the listing table');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.bid(3)::text,true);
select api.moderate_listing(pg_temp.result_id('a1'),true);
select api.moderate_listing(pg_temp.result_id('a2'),true);
reset role;

set local role anon;
select set_config('request.jwt.claim.sub','',true);
select pg_temp.ok(
  (select to_jsonb(l) ?& array['slug','display_name','description','city','timezone']
   and not (to_jsonb(l) ?| array['organization_id','location_id','moderated_by','status'])
   from api.discover_listings('fixture-a1') l),'published projection has an explicit field allowlist');
select pg_temp.ok((api.booking_availability('fixture-a1',pg_temp.bid(71),pg_temp.slot(9))->>'available')::boolean,'open slot available');
select pg_temp.ok(not (api.booking_availability('fixture-a1',pg_temp.bid(71),pg_temp.slot(8))->>'available')::boolean,'closed hours rejected');

select set_config('booking.fixture_first',api.submit_booking_request('fixture-a1',pg_temp.bid(71),pg_temp.slot(9),'Guest','guest@example.test',pg_temp.bid(101))::text,true);
select pg_temp.ok(api.submit_booking_request('fixture-a1',pg_temp.bid(71),pg_temp.slot(9),'Guest','guest@example.test',pg_temp.bid(101))=pg_temp.result_id('first'),'submission replay returns same request');
select pg_temp.fails($stmt$select api.submit_booking_request('fixture-a1',pg_temp.bid(71),pg_temp.slot(9),'Other','other@example.test',pg_temp.bid(101))$stmt$,'22023','changed replay payload rejected');
select set_config('booking.fixture_room',api.submit_booking_request('fixture-a1',pg_temp.bid(72),pg_temp.slot(9),'Guest','guest@example.test',pg_temp.bid(102))::text,true);
select set_config('booking.fixture_crossbranch',api.submit_booking_request('fixture-a2',pg_temp.bid(71),pg_temp.slot(9),'Guest','guest@example.test',pg_temp.bid(103))::text,true);
select set_config('booking.fixture_next',api.submit_booking_request('fixture-a1',pg_temp.bid(72),pg_temp.slot(9,30),'Guest','guest@example.test',pg_temp.bid(104))::text,true);
select pg_temp.ok((api.booking_availability('fixture-a1',pg_temp.bid(71),pg_temp.slot(9))->>'available')::boolean,'unaccepted requests do not hold slots');
select pg_temp.fails('select * from api.booking_inbox(pg_temp.bid(21))','42501','anonymous inbox execution denied');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.bid(4)::text,true);
select pg_temp.fails('select * from api.booking_inbox(pg_temp.bid(21))','42501','other tenant inbox denied');
select pg_temp.fails('select api.decide_booking_request(pg_temp.result_id(''first''),true)','42501','other tenant decision denied');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.bid(2)::text,true);
select pg_temp.ok((select count(*) from api.booking_inbox(pg_temp.bid(21)))=3,'manager reads assigned inbox');
select pg_temp.fails('select * from api.booking_inbox(pg_temp.bid(22))','42501','manager cannot read another branch inbox');
select pg_temp.fails('select api.decide_booking_request(pg_temp.result_id(''crossbranch''),true)','42501','manager cannot decide another branch request');
select set_config('booking.fixture_appointment',(api.decide_booking_request(pg_temp.result_id('first'),true)->>'appointment_id'),true);
select pg_temp.ok((api.decide_booking_request(pg_temp.result_id('first'),true)->>'appointment_id')::uuid=pg_temp.result_id('appointment'),
  'repeated acceptance returns the same appointment');
select pg_temp.fails('select api.decide_booking_request(pg_temp.result_id(''room''),true)','23P01','room conflict blocks different staff');
select set_config('booking.fixture_adjacent',(api.decide_booking_request(pg_temp.result_id('next'),true)->>'appointment_id'),true);
select pg_temp.ok(pg_temp.result_id('adjacent')<>pg_temp.result_id('appointment'),'adjacent room bookings allowed');
select pg_temp.fails('select api.reschedule_appointment(pg_temp.result_id(''appointment''),pg_temp.slot(9,30))',
  '23P01','reschedule conflict is rejected');
select pg_temp.ok(exists(select from api.booking_calendar(pg_temp.bid(21),pg_temp.slot(8),pg_temp.slot(17))
  where id=pg_temp.result_id('appointment') and starts_at=pg_temp.slot(9)),'failed reschedule preserves the original appointment');
select pg_temp.ok((api.reschedule_appointment(pg_temp.result_id('appointment'),pg_temp.slot(10))->>'starts_at')::timestamptz=pg_temp.slot(10),
  'new time claimed on successful reschedule');
select pg_temp.ok(api.cancel_appointment(pg_temp.result_id('adjacent'))='cancelled','owner workflow cancels an appointment');
select pg_temp.ok(api.cancel_appointment(pg_temp.result_id('adjacent'))='cancelled','cancellation replay is safe');
select pg_temp.ok((api.decide_booking_request(pg_temp.result_id('room'),false)->>'status')='declined','request can be declined');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.bid(1)::text,true);
select set_config('booking.fixture_cross_later',api.submit_booking_request('fixture-a2',pg_temp.bid(71),pg_temp.slot(11),'Cross','guest@example.test',pg_temp.bid(105))::text,true);
select set_config('booking.fixture_first_later',api.submit_booking_request('fixture-a1',pg_temp.bid(71),pg_temp.slot(11),'First','first-later@example.test',pg_temp.bid(106))::text,true);
select api.decide_booking_request(pg_temp.result_id('first_later'),true);
select pg_temp.fails('select api.decide_booking_request(pg_temp.result_id(''cross_later''),true)','23P01','staff cannot be booked in two branches at once');
reset role;
select pg_temp.ok(
  (select count(*) from ops.appointments where booking_request_id=pg_temp.result_id('first'))=1
  and (select count(*) from ops.appointment_allocations where appointment_id=pg_temp.result_id('appointment') and is_blocking)=2
  and (select count(*) from ops.appointment_allocations where appointment_id=pg_temp.result_id('adjacent') and is_blocking)=0
  and (select count(*) from ops.outbox_events where aggregate_id=pg_temp.result_id('first') and event_type='booking.submitted')=1
  and not exists (select from core.client_account_links where organization_id=pg_temp.bid(10)),
  'one accepted appointment, correct allocations and outbox, no automatic account linking');
rollback;
