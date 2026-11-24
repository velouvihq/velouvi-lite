\set ON_ERROR_STOP on
begin;
create function pg_temp.tid(n integer) returns uuid language sql immutable as $$
  select ('a4000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.ok(passed boolean,label text) returns void language plpgsql as $$
begin
  if passed is distinct from true then raise exception 'FAIL %',label; end if;
  raise notice 'PASS %',label;
end;
$$;
create function pg_temp.denied(statement text,label text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when insufficient_privilege then raise notice 'PASS %',label; return; end;
  raise exception 'FAIL % was allowed',label;
end;
$$;
create function pg_temp.value_for(k text) returns uuid language sql stable as $$
  select current_setting('pilot.fixture_'||k)::uuid;
$$;
create function pg_temp.visit() returns timestamptz language sql stable as $$
  select (((now() at time zone 'Asia/Colombo')::date+1)+time '10:00') at time zone 'Asia/Colombo';
$$;
insert into auth.users(id,email,email_confirmed_at) values
  (pg_temp.tid(1),'pilot-owner@example.test',now()),
  (pg_temp.tid(2),'pilot-guest@example.test',now()),
  (pg_temp.tid(3),'pilot-other@example.test',now());

set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.tid(1)::text,true);
do $$
declare created jsonb;
begin
  created:=api.create_booking_business('Pilot salon','pilot-test-salon','Main branch');
  perform set_config('pilot.fixture_org',created->>'organization_id',true);
  perform set_config('pilot.fixture_branch',created->>'location_id',true);
end;
$$;
select api.add_booking_staff(pg_temp.value_for('branch'),'Pilot Stylist');
select api.set_booking_week(pg_temp.value_for('branch'),array[0,1,2,3,4,5,6]::smallint[],'09:00','17:00');
select set_config('pilot.fixture_service',api.add_bookable_service(pg_temp.value_for('branch'),'Pilot service',30,1200000)::text,true);
select set_config('pilot.fixture_listing',api.save_listing(pg_temp.value_for('branch'),'pilot-fixture','Pilot salon','Pilot description')::text,true);
select pg_temp.ok((select count(*) from api.booking_listing_draft(pg_temp.value_for('branch')))=1,'owner can see own draft');
select pg_temp.denied('select * from api.listing_review_queue()','owner cannot view moderation queue');
select set_config('pilot.fixture_team_token',api.issue_team_invitation(
  pg_temp.value_for('branch'),'pilot-other@example.test','manager'),true);
select set_config('request.jwt.claim.sub',pg_temp.tid(2)::text,true);
select pg_temp.denied('select api.accept_team_invitation(current_setting(''pilot.fixture_team_token''))',
  'invitation rejects a different verified email');
select set_config('request.jwt.claim.sub',pg_temp.tid(3)::text,true);
select pg_temp.ok(api.accept_team_invitation(current_setting('pilot.fixture_team_token'))=pg_temp.value_for('branch'),
  'intended teammate accepts branch invitation');
select pg_temp.denied('select api.accept_team_invitation(current_setting(''pilot.fixture_team_token''))',
  'consumed team invitation cannot be replayed');
select pg_temp.ok((select count(*) from api.booking_locations())=1,'new manager sees one assigned branch');
select set_config('request.jwt.claim.sub',pg_temp.tid(1)::text,true);
select api.revoke_booking_team_assignment((select assignment_id from api.booking_team(pg_temp.value_for('branch'))));
select set_config('request.jwt.claim.sub',pg_temp.tid(3)::text,true);
select pg_temp.ok((select count(*) from api.booking_locations())=0,'removed team assignment takes effect immediately');
select set_config('request.jwt.claim.sub',pg_temp.tid(1)::text,true);
select pg_temp.ok((api.booking_plan_status(pg_temp.value_for('org'))->>'plan')='free','new salon has free plan');
select pg_temp.ok((api.start_lite_trial(pg_temp.value_for('org'))->>'plan')='lite','trial activates Lite');
select pg_temp.ok((api.start_lite_trial(pg_temp.value_for('org'))->>'trial_ends_at')::timestamptz=now()+interval '7 days',
  'trial repeat does not extend access');
reset role;
update billing.subscriptions set period_start=now()-interval '8 days',period_end=now()-interval '1 day'
where organization_id=pg_temp.value_for('org');
update marketplace.listings set status='published' where id=pg_temp.value_for('listing');

set local role anon;
select set_config('request.jwt.claim.sub','',true);
select set_config('pilot.fixture_request',api.submit_booking_request('pilot-fixture',pg_temp.value_for('service'),pg_temp.visit(),
  'Pilot Guest','pilot-guest@example.test',pg_temp.tid(11))::text,true);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.tid(1)::text,true);
select pg_temp.ok((api.booking_plan_status(pg_temp.value_for('org'))->>'plan')='free'
  and (select count(*) from api.booking_inbox(pg_temp.value_for('branch')))=1,'expired trial falls back to free and keeps the same inbox');
select set_config('pilot.fixture_appointment',api.decide_booking_request(pg_temp.value_for('request'),true)->>'appointment_id',true);
select set_config('pilot.fixture_client',(select primary_client_id::text from ops.appointments where id=pg_temp.value_for('appointment')),true);
select set_config('pilot.fixture_token',api.issue_client_claim(pg_temp.value_for('client')),true);
select set_config('pilot.fixture_order',api.prepare_payhere_sandbox_order(pg_temp.value_for('appointment'))->>'id',true);
select pg_temp.ok((api.prepare_payhere_sandbox_order(pg_temp.value_for('appointment'))->>'id')::uuid=pg_temp.value_for('order'),
  'sandbox order creation is idempotent');
select pg_temp.denied(
  'select api.record_payhere_sandbox_event(pg_temp.value_for(''order''),1200000,''LKR'',''2'',''fake'')',
  'owner cannot record payment provider results');
select pg_temp.denied('select * from api.claim_booking_notifications(1)','owner cannot claim notification deliveries');

select set_config('request.jwt.claim.sub',pg_temp.tid(3)::text,true);
select pg_temp.denied('select api.redeem_client_claim(current_setting(''pilot.fixture_token''))',
  'wrong verified email cannot redeem the token');
select pg_temp.denied('select * from api.client_contacts(pg_temp.value_for(''client''))','unlinked account cannot read contacts');

select set_config('request.jwt.claim.sub',pg_temp.tid(2)::text,true);
select pg_temp.ok((select count(*) from api.my_appointments())=0,'matching email alone does not reveal appointment');
select pg_temp.ok(api.redeem_client_claim(current_setting('pilot.fixture_token'))=pg_temp.value_for('client'),'verified customer redeems one-time token');
select pg_temp.denied('select api.redeem_client_claim(current_setting(''pilot.fixture_token''))','claim redemption replay denied');
select pg_temp.ok(exists(select from api.client_contacts(pg_temp.value_for('client')) where is_verified),'claim verifies primary contact');
select pg_temp.ok((select count(*) from api.my_appointments())=1,'linked client can read own appointment');
select api.record_client_consent(pg_temp.value_for('client'),'marketing','email','pilot-v1',true);
select api.record_client_consent(pg_temp.value_for('client'),'marketing','email','pilot-v1',false);
select set_config('pilot.fixture_grant',api.delegate_client_booking(pg_temp.value_for('appointment'),pg_temp.tid(3),now()+interval '3 days')::text,true);
select set_config('request.jwt.claim.sub',pg_temp.tid(3)::text,true);
select pg_temp.ok((select count(*) from api.my_appointments())=1,'delegation permits one appointment');
select pg_temp.denied('select * from api.client_contacts(pg_temp.value_for(''client''))','delegation does not permit client contacts');
select set_config('request.jwt.claim.sub',pg_temp.tid(2)::text,true);
select api.revoke_client_delegation(pg_temp.value_for('grant'));
select set_config('request.jwt.claim.sub',pg_temp.tid(3)::text,true);
select pg_temp.ok((select count(*) from api.my_appointments())=0,'revoked delegation stops access');
reset role;

set local role service_role;
select set_config('request.jwt.claim.sub','',true);
do $$
declare job record;
begin
  select * into job from api.claim_booking_notifications(5)
  where reference=pg_temp.value_for('appointment')::text;
  perform pg_temp.ok(job.recipient_email='pilot-guest@example.test','worker claim resolves only scoped contact');
  perform pg_temp.ok(not api.finish_booking_notification(job.event_id,pg_temp.tid(999),'sent','wrong-lease'),
    'stale worker cannot complete notification');
  perform pg_temp.ok(api.finish_booking_notification(job.event_id,job.lease,'sent','test-reference'),'current lease records successful delivery');
  perform pg_temp.ok((select count(*)=0 from api.claim_booking_notifications(5)),'completed event is not redelivered');
end;
$$;
select pg_temp.ok(api.record_payhere_sandbox_event(pg_temp.value_for('order'),1,'LKR','2','sample')='amount_mismatch',
  'wrong sandbox amount recorded without setting paid');
select pg_temp.ok(api.record_payhere_sandbox_event(pg_temp.value_for('order'),1200000,'LKR','2','sample')='applied','valid sandbox event marks order paid');
select pg_temp.ok(api.record_payhere_sandbox_event(pg_temp.value_for('order'),1200000,'LKR','2','sample')='ignored','sandbox replay ignored');
select pg_temp.ok(api.record_payhere_sandbox_event(pg_temp.value_for('order'),1200000,'LKR','0','sample')='ignored','late pending cannot overwrite paid');
select pg_temp.ok(api.record_payhere_sandbox_event(pg_temp.value_for('order'),1200000,'LKR','-3','sample')='applied','chargeback recorded');
reset role;
select pg_temp.ok((select payment_status='not_required' from ops.appointments where id=pg_temp.value_for('appointment')),
  'sandbox does not affect live appointment payment status');
select pg_temp.ok((select count(*)=2 and count(*) filter(where consented)=1
  from core.client_consents where client_id=pg_temp.value_for('client')),'consent and withdrawal have separate history records');
update ops.appointments set status='held',held_until=now()-interval '1 minute'
where id=pg_temp.value_for('appointment');
set local role service_role;
select pg_temp.ok(api.expire_booking_holds()=1,'expired hold worker expires one held appointment');
reset role;
select pg_temp.ok(
  (select status='expired' from ops.appointments where id=pg_temp.value_for('appointment'))
  and not exists(select from ops.appointment_allocations
    where appointment_id=pg_temp.value_for('appointment') and is_blocking),
  'expired holds release allocations and remain recorded');
rollback;
