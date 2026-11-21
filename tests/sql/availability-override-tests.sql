-- Behaviour tests against synthetic records in disposable PostgreSQL.
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
set test.is_admin = 'true';

create or replace function pg_temp.assert_true(p_value boolean, p_message text)
returns void language plpgsql as $$
begin
  if p_value is distinct from true then
    raise exception 'ASSERTION FAILED: %', p_message;
  end if;
end;
$$;

create or replace function pg_temp.expect_error(p_sql text, p_expected text)
returns void language plpgsql as $$
declare
  v_message text;
begin
  begin
    execute p_sql;
    raise exception 'TEST EXPECTED AN ERROR BUT THE STATEMENT SUCCEEDED';
  exception when others then
    get stacked diagnostics v_message = message_text;
    if v_message = 'TEST EXPECTED AN ERROR BUT THE STATEMENT SUCCEEDED' then
      raise;
    end if;
    if position(p_expected in v_message) = 0 then
      raise exception 'EXPECTED ERROR CONTAINING "%", GOT "%"', p_expected, v_message;
    end if;
  end;
end;
$$;

insert into public.profiles (id, full_name, role) values
('00000000-0000-0000-0000-000000000001', 'Synthetic Admin', 'admin'),
('00000000-0000-0000-0000-000000000011', 'Assistant Available', 'assistant'),
('00000000-0000-0000-0000-000000000012', 'Assistant Unavailable', 'assistant'),
('00000000-0000-0000-0000-000000000013', 'Assistant No Availability', 'assistant'),
('00000000-0000-0000-0000-000000000014', 'Assistant Partial Hours', 'assistant'),
('00000000-0000-0000-0000-000000000015', 'Assistant Conflict', 'assistant');

insert into public.assistants (id, profile_id) values
('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000011'),
('10000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000012'),
('10000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000013'),
('10000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000014'),
('10000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000015');

insert into public.surgical_cases
(id, hospital_id, procedure_id, surgeon_id, case_date, start_time, finish_time, status)
values
('20000000-0000-0000-0000-000000000011', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-01', '10:00', '12:00', 'unmatched'),
('20000000-0000-0000-0000-000000000012', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-02', '10:00', '12:00', 'unmatched'),
('20000000-0000-0000-0000-000000000013', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-03', '10:00', '12:00', 'unmatched'),
('20000000-0000-0000-0000-000000000014', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-04', '10:00', '12:00', 'unmatched'),
('20000000-0000-0000-0000-000000000015', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-05', '10:00', '12:00', 'unmatched'),
('20000000-0000-0000-0000-000000000016', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '2026-12-05', '10:30', '11:30', 'confirmed');

update public.surgical_cases
set assistant_id = '10000000-0000-0000-0000-000000000015'
where id = '20000000-0000-0000-0000-000000000016';

insert into public.availability (assistant_id, availability_date, availability_type, start_time, finish_time) values
('10000000-0000-0000-0000-000000000011', '2026-12-01', 'full_day', null, null),
('10000000-0000-0000-0000-000000000012', '2026-12-02', 'unavailable', null, null),
('10000000-0000-0000-0000-000000000014', '2026-12-04', 'specific_hours', '08:00', '11:00');

do $$
declare
  v_match record;
  v_invitation uuid;
  v_details jsonb;
begin
  -- Full-day availability: normal allocation succeeds without override.
  select * into v_match from public.check_assistant_matching('20000000-0000-0000-0000-000000000011')
  where assistant_id = '10000000-0000-0000-0000-000000000011';
  perform pg_temp.assert_true(v_match.availability_match, 'full-day availability should match');
  perform pg_temp.assert_true(v_match.availability_submitted, 'full-day availability should be submitted');
  perform pg_temp.assert_true(not v_match.explicitly_unavailable, 'full-day availability is not unavailable');
  v_invitation := public.allocate_assistant('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000011', false, null);
  perform pg_temp.assert_true(v_invitation is not null, 'normal allocation returns invitation id');

  -- Explicitly unavailable: warning flag and reason are mandatory; valid override is logged.
  select * into v_match from public.check_assistant_matching('20000000-0000-0000-0000-000000000012')
  where assistant_id = '10000000-0000-0000-0000-000000000012';
  perform pg_temp.assert_true(not v_match.availability_match, 'unavailable must not match');
  perform pg_temp.assert_true(v_match.availability_submitted, 'unavailable entry counts as submitted');
  perform pg_temp.assert_true(v_match.explicitly_unavailable, 'explicit unavailability is identified');
  perform pg_temp.expect_error(
    $$select public.allocate_assistant('20000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000012',false,null)$$,
    'Explicit acknowledgement'
  );
  perform pg_temp.expect_error(
    $$select public.allocate_assistant('20000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000012',true,' ')$$,
    'explanation is required'
  );
  v_invitation := public.allocate_assistant('20000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000012', true, 'Operational cover agreed with assistant');
  select details into v_details from public.audit_logs where entity_id = '20000000-0000-0000-0000-000000000012';
  perform pg_temp.assert_true((v_details->>'explicitly_unavailable')::boolean, 'audit records explicit unavailability');
  perform pg_temp.assert_true((v_details->>'availability_submitted')::boolean, 'audit records submitted availability');
  perform pg_temp.assert_true(v_details->>'override_reason' = 'Operational cover agreed with assistant', 'audit records override reason');

  -- No availability submitted: distinguish from explicit unavailability.
  select * into v_match from public.check_assistant_matching('20000000-0000-0000-0000-000000000013')
  where assistant_id = '10000000-0000-0000-0000-000000000013';
  perform pg_temp.assert_true(not v_match.availability_match, 'missing availability must not match');
  perform pg_temp.assert_true(not v_match.availability_submitted, 'missing availability is not submitted');
  perform pg_temp.assert_true(not v_match.explicitly_unavailable, 'missing availability is not explicit unavailability');
  perform pg_temp.expect_error(
    $$select public.allocate_assistant('20000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000013',true,null)$$,
    'explanation is required'
  );
  perform public.allocate_assistant('20000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000013', true, 'No response received');

  -- Submitted partial hours: distinct from missing availability and requires override.
  select * into v_match from public.check_assistant_matching('20000000-0000-0000-0000-000000000014')
  where assistant_id = '10000000-0000-0000-0000-000000000014';
  perform pg_temp.assert_true(not v_match.availability_match, 'partial hours do not cover full case');
  perform pg_temp.assert_true(v_match.availability_submitted, 'partial hours are submitted');
  perform pg_temp.assert_true(not v_match.explicitly_unavailable, 'partial hours are not explicit unavailability');
  perform public.allocate_assistant('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000014', true, 'Operational exception approved');

  -- Overlapping confirmed booking remains blocked even with an override and reason.
  select * into v_match from public.check_assistant_matching('20000000-0000-0000-0000-000000000015')
  where assistant_id = '10000000-0000-0000-0000-000000000015';
  perform pg_temp.assert_true(v_match.booking_conflict, 'overlapping booking is detected');
  perform pg_temp.expect_error(
    $$select public.allocate_assistant('20000000-0000-0000-0000-000000000015','10000000-0000-0000-0000-000000000015',true,'Must remain blocked')$$,
    'Booking conflict'
  );
end;
$$;

select 'PASS: availability override SQL behaviour tests completed' as test_result;
