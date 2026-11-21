-- Synthetic schema only. This file is for an isolated PostgreSQL CI database.
-- It contains no production data, credentials, or Supabase project connection.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon;
  end if;
end;
$$;

create schema if not exists auth;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('test.is_admin', true), 'false') = 'true';
$$;

create table public.profiles (
  id uuid primary key,
  full_name text not null,
  role text not null,
  created_at timestamptz default now()
);

create table public.assistants (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  active boolean not null default true,
  experience_notes text,
  created_at timestamptz default now()
);

create table public.surgical_cases (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null,
  procedure_id uuid not null,
  surgeon_id uuid not null,
  case_date date not null,
  start_time time not null,
  finish_time time not null,
  assistant_id uuid references public.assistants(id),
  status text not null default 'unmatched',
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint surgical_cases_valid_times check (finish_time > start_time)
);

create table public.availability (
  id uuid primary key default gen_random_uuid(),
  assistant_id uuid not null references public.assistants(id),
  availability_date date not null,
  availability_type text not null,
  start_time time,
  finish_time time,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.surgical_cases(id),
  assistant_id uuid not null references public.assistants(id),
  status text not null default 'pending',
  invited_at timestamptz not null default now(),
  responded_at timestamptz,
  response_note text
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
