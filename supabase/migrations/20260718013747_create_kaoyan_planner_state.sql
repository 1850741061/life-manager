create table if not exists public.kaoyan_planner_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now(),
  constraint kaoyan_planner_payload_is_object check (jsonb_typeof(payload) = 'object')
);

alter table public.kaoyan_planner_state enable row level security;

revoke all on table public.kaoyan_planner_state from anon, authenticated;
grant select, insert, update on table public.kaoyan_planner_state to authenticated;

drop policy if exists kaoyan_planner_select_own on public.kaoyan_planner_state;
create policy kaoyan_planner_select_own
on public.kaoyan_planner_state
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists kaoyan_planner_insert_own on public.kaoyan_planner_state;
create policy kaoyan_planner_insert_own
on public.kaoyan_planner_state
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists kaoyan_planner_update_own on public.kaoyan_planner_state;
create policy kaoyan_planner_update_own
on public.kaoyan_planner_state
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

comment on table public.kaoyan_planner_state is 'Single-user-per-account cloud state for the Kaoyan 27 planner.';
