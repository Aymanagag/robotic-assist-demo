-- Distinguish explicit unavailability from missing/mismatched availability.
-- Proposed migration only: do not apply to production until reviewed and approved.

begin;

drop function if exists public.check_assistant_matching(uuid);

create function public.check_assistant_matching(p_case_id uuid)
returns table (
  assistant_id uuid,
  assistant_name text,
  availability_match boolean,
  explicitly_unavailable boolean,
  platform_match boolean,
  booking_conflict boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  if not exists (select 1 from public.surgical_cases c where c.id = p_case_id) then
    raise exception 'Surgical case not found';
  end if;

  return query
  select
    a.id,
    p.full_name,
    (
      not exists (
        select 1 from public.availability av
        where av.assistant_id = a.id
          and av.availability_date = c.case_date
          and av.availability_type = 'unavailable'
      )
      and exists (
        select 1 from public.availability av
        where av.assistant_id = a.id
          and av.availability_date = c.case_date
          and (
            av.availability_type = 'full_day'
            or (
              av.availability_type = 'specific_hours'
              and av.start_time <= c.start_time
              and av.finish_time >= c.finish_time
            )
          )
      )
    ) as availability_match,
    exists (
      select 1 from public.availability av
      where av.assistant_id = a.id
        and av.availability_date = c.case_date
        and av.availability_type = 'unavailable'
    ) as explicitly_unavailable,
    true as platform_match,
    exists (
      select 1 from public.surgical_cases other_case
      where other_case.assistant_id = a.id
        and other_case.id <> c.id
        and other_case.case_date = c.case_date
        and other_case.status in ('invited', 'confirmed')
        and other_case.start_time < c.finish_time
        and other_case.finish_time > c.start_time
    ) as booking_conflict
  from public.assistants a
  join public.profiles p on p.id = a.profile_id
  cross join public.surgical_cases c
  where c.id = p_case_id
    and a.active = true
  order by p.full_name;
end;
$function$;

revoke all on function public.check_assistant_matching(uuid) from public, anon;
grant execute on function public.check_assistant_matching(uuid) to authenticated;

create or replace function public.allocate_assistant(
  p_case_id uuid,
  p_assistant_id uuid,
  p_override_warnings boolean default false,
  p_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_case public.surgical_cases%rowtype;
  v_assistant public.assistants%rowtype;
  v_availability_match boolean;
  v_explicitly_unavailable boolean;
  v_platform_match boolean;
  v_conflict boolean;
  v_invitation_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  select * into v_case
  from public.surgical_cases
  where id = p_case_id
  for update;

  if not found then
    raise exception 'Surgical case not found';
  end if;

  if v_case.status <> 'unmatched' then
    raise exception 'Case is not available for allocation';
  end if;

  select * into v_assistant
  from public.assistants
  where id = p_assistant_id and active = true
  for update;

  if not found then
    raise exception 'Active assistant not found';
  end if;

  select exists (
    select 1 from public.surgical_cases c
    where c.assistant_id = p_assistant_id
      and c.id <> p_case_id
      and c.case_date = v_case.case_date
      and c.status in ('invited', 'confirmed')
      and c.start_time < v_case.finish_time
      and c.finish_time > v_case.start_time
  ) into v_conflict;

  if v_conflict then
    raise exception 'Booking conflict: assistant already has an overlapping case. Allocation blocked.';
  end if;

  select exists (
    select 1 from public.availability av
    where av.assistant_id = p_assistant_id
      and av.availability_date = v_case.case_date
      and av.availability_type = 'unavailable'
  ) into v_explicitly_unavailable;

  select (
    not v_explicitly_unavailable
    and exists (
      select 1 from public.availability av
      where av.assistant_id = p_assistant_id
        and av.availability_date = v_case.case_date
        and (
          av.availability_type = 'full_day'
          or (
            av.availability_type = 'specific_hours'
            and av.start_time <= v_case.start_time
            and av.finish_time >= v_case.finish_time
          )
        )
    )
  ) into v_availability_match;

  v_platform_match := true;

  if not v_availability_match
     and p_override_warnings is distinct from true then
    raise exception 'Warning: assistant availability does not cover the full case. Explicit acknowledgement is required to proceed.';
  end if;

  if not v_availability_match
     and nullif(trim(p_override_reason), '') is null then
    raise exception 'An explanation is required when overriding warnings.';
  end if;

  insert into public.invitations (case_id, assistant_id, status)
  values (p_case_id, p_assistant_id, 'pending')
  returning id into v_invitation_id;

  update public.surgical_cases
  set assistant_id = p_assistant_id,
      status = 'invited',
      updated_at = now()
  where id = p_case_id;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    'assistant_invited',
    'surgical_case',
    p_case_id,
    jsonb_build_object(
      'assistant_id', p_assistant_id,
      'availability_match', v_availability_match,
      'explicitly_unavailable', v_explicitly_unavailable,
      'platform_match', v_platform_match,
      'availability_override', not v_availability_match,
      'platform_override', not v_platform_match,
      'override_reason', p_override_reason
    )
  );

  return v_invitation_id;
end;
$function$;

revoke all on function public.allocate_assistant(uuid, uuid, boolean, text) from public, anon;
grant execute on function public.allocate_assistant(uuid, uuid, boolean, text) to authenticated;

commit;
