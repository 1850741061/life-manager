-- Canonical cross-client sync contract for all ProLife desktop and Android clients.
-- The migration is intentionally idempotent at the data level; schema objects use
-- stable names so later projects can mirror the exact same contract.

-- Keep this already-applied migration self-contained for fresh environments.
-- Supabase only records migration versions (not file checksums), so extending
-- the local source with an idempotent baseline does not replay it in production.
create table if not exists public.user_data (
  id uuid primary key references auth.users(id) on delete cascade,
  todos jsonb not null default '[]'::jsonb,
  transactions jsonb not null default '[]'::jsonb,
  groups jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default pg_catalog.now(),
  templates jsonb not null default '[]'::jsonb,
  archivedtodos jsonb not null default '[]'::jsonb,
  habits jsonb not null default '[]'::jsonb,
  habitrecords jsonb not null default '{}'::jsonb,
  projects jsonb not null default '[]'::jsonb,
  "archivedTodos" jsonb not null default '[]'::jsonb,
  "habitRecords" jsonb not null default '{}'::jsonb,
  milktea jsonb not null default '{"records":[],"settings":{"weeklyLimit":2,"monthlyLimit":8}}'::jsonb,
  "dailyPlans" jsonb not null default '[]'::jsonb,
  coffee jsonb not null default '{"records":[],"settings":{"weeklyLimit":3,"monthlyLimit":12}}'::jsonb,
  deletedids jsonb not null default '[]'::jsonb,
  ideas jsonb not null default '[]'::jsonb,
  "ideaTags" jsonb not null default '[]'::jsonb,
  "focusSessions" jsonb not null default '[]'::jsonb
);

alter table public.user_data
  add column if not exists id uuid,
  add column if not exists todos jsonb not null default '[]'::jsonb,
  add column if not exists transactions jsonb not null default '[]'::jsonb,
  add column if not exists groups jsonb not null default '[]'::jsonb,
  add column if not exists updated_at timestamptz not null default pg_catalog.now(),
  add column if not exists templates jsonb not null default '[]'::jsonb,
  add column if not exists archivedtodos jsonb not null default '[]'::jsonb,
  add column if not exists habits jsonb not null default '[]'::jsonb,
  add column if not exists habitrecords jsonb not null default '{}'::jsonb,
  add column if not exists projects jsonb not null default '[]'::jsonb,
  add column if not exists "archivedTodos" jsonb not null default '[]'::jsonb,
  add column if not exists "habitRecords" jsonb not null default '{}'::jsonb,
  add column if not exists milktea jsonb not null default '{"records":[],"settings":{"weeklyLimit":2,"monthlyLimit":8}}'::jsonb,
  add column if not exists "dailyPlans" jsonb not null default '[]'::jsonb,
  add column if not exists coffee jsonb not null default '{"records":[],"settings":{"weeklyLimit":3,"monthlyLimit":12}}'::jsonb,
  add column if not exists deletedids jsonb not null default '[]'::jsonb,
  add column if not exists ideas jsonb not null default '[]'::jsonb,
  add column if not exists "ideaTags" jsonb not null default '[]'::jsonb,
  add column if not exists "focusSessions" jsonb not null default '[]'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.user_data'::pg_catalog.regclass and contype = 'p'
  ) then
    alter table public.user_data add constraint user_data_pkey primary key (id);
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.user_data'::pg_catalog.regclass
      and conname = 'user_data_id_fkey'
  ) then
    alter table public.user_data
      add constraint user_data_id_fkey foreign key (id) references auth.users(id) on delete cascade;
  end if;
end;
$$;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.try_timestamptz(value text)
returns timestamptz
language plpgsql
immutable
set search_path = ''
as $$
begin
  if value is null or btrim(value) = '' then
    return null;
  end if;
  return value::timestamptz;
exception when others then
  return null;
end;
$$;

create or replace function private.normalize_legacy_numeric_id(value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  normalized text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(value, '')), '^tx_', '', 'i');
begin
  if normalized ~ '^[0-9]+$' then
    return (normalized::numeric)::text;
  end if;
  return normalized;
exception when others then
  return normalized;
end;
$$;

create or replace function private.merge_sync_arrays(left_value jsonb, right_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  existing jsonb;
  item_key text;
  item_time timestamptz;
  existing_time timestamptz;
  by_key jsonb := '{}'::jsonb;
  result jsonb;
begin
  for item in
    select value
    from pg_catalog.jsonb_array_elements(
      case when pg_catalog.jsonb_typeof(left_value) = 'array' then left_value else '[]'::jsonb end
    )
    union all
    select value
    from pg_catalog.jsonb_array_elements(
      case when pg_catalog.jsonb_typeof(right_value) = 'array' then right_value else '[]'::jsonb end
    )
  loop
    item_key := coalesce(item->>'id', 'json:' || pg_catalog.md5(item::text));
    existing := by_key->item_key;
    if existing is null then
      by_key := by_key || pg_catalog.jsonb_build_object(item_key, item);
      continue;
    end if;

    item_time := coalesce(
      private.try_timestamptz(item->>'updatedAt'),
      private.try_timestamptz(item->>'archivedAt'),
      private.try_timestamptz(item->>'createdAt'),
      '-infinity'::timestamptz
    );
    existing_time := coalesce(
      private.try_timestamptz(existing->>'updatedAt'),
      private.try_timestamptz(existing->>'archivedAt'),
      private.try_timestamptz(existing->>'createdAt'),
      '-infinity'::timestamptz
    );

    if item_time > existing_time or (item_time = existing_time and item::text > existing::text) then
      by_key := by_key || pg_catalog.jsonb_build_object(item_key, existing || item);
    else
      by_key := by_key || pg_catalog.jsonb_build_object(item_key, item || existing);
    end if;
  end loop;

  select coalesce(pg_catalog.jsonb_agg(value order by key), '[]'::jsonb)
    into result
  from pg_catalog.jsonb_each(by_key);
  return result;
end;
$$;

create or replace function private.merge_sync_json(left_value jsonb, right_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  key_name text;
  result jsonb := '{}'::jsonb;
begin
  if left_value is null then return right_value; end if;
  if right_value is null then return left_value; end if;
  if left_value = right_value then return left_value; end if;

  if pg_catalog.jsonb_typeof(left_value) = 'array' and pg_catalog.jsonb_typeof(right_value) = 'array' then
    return private.merge_sync_arrays(left_value, right_value);
  end if;

  if pg_catalog.jsonb_typeof(left_value) = 'object' and pg_catalog.jsonb_typeof(right_value) = 'object' then
    for key_name in
      select key from (
        select key from pg_catalog.jsonb_object_keys(left_value) as key
        union
        select key from pg_catalog.jsonb_object_keys(right_value) as key
      ) keys
      order by key
    loop
      if not (left_value ? key_name) then
        result := result || pg_catalog.jsonb_build_object(key_name, right_value->key_name);
      elsif not (right_value ? key_name) then
        result := result || pg_catalog.jsonb_build_object(key_name, left_value->key_name);
      else
        result := result || pg_catalog.jsonb_build_object(
          key_name,
          private.merge_sync_json(left_value->key_name, right_value->key_name)
        );
      end if;
    end loop;
    return result;
  end if;

  if left_value::text >= right_value::text then return left_value; end if;
  return right_value;
end;
$$;

create or replace function private.normalize_record_array(value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  timestamp_value text;
  result jsonb := '[]'::jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'array' then return result; end if;
  for item in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    if pg_catalog.jsonb_typeof(item) = 'object' and not (item ? 'updatedAt') then
      timestamp_value := coalesce(
        nullif(item->>'createdAt', ''),
        nullif(item->>'archivedAt', ''),
        nullif(item->>'completedAt', ''),
        nullif(item->>'endedAt', ''),
        nullif(item->>'startedAt', ''),
        case
          when coalesce(item->>'date', '') ~ '^\\d{4}-\\d{2}-\\d{2}$'
            then (item->>'date') || 'T00:00:00.000Z'
          else '1970-01-01T00:00:00.000Z'
        end
      );
      item := pg_catalog.jsonb_set(item, '{updatedAt}', pg_catalog.to_jsonb(timestamp_value), true);
    end if;
    result := result || pg_catalog.jsonb_build_array(item);
  end loop;
  return result;
end;
$$;

create or replace function private.normalize_transactions(value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  result jsonb := '[]'::jsonb;
begin
  for item in
    select entry from pg_catalog.jsonb_array_elements(private.normalize_record_array(value)) entry
  loop
    if pg_catalog.jsonb_typeof(item) = 'object' then
      if pg_catalog.jsonb_typeof(item->'amount') = 'string'
         and coalesce(item->>'amount', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$' then
        item := pg_catalog.jsonb_set(
          item,
          '{amount}',
          pg_catalog.to_jsonb((item->>'amount')::numeric),
          true
        );
      end if;
      if not (item ? 'createdAt') then
        item := pg_catalog.jsonb_set(item, '{createdAt}', item->'updatedAt', true);
      end if;
    end if;
    result := result || pg_catalog.jsonb_build_array(item);
  end loop;
  return result;
end;
$$;

create or replace function private.normalize_drink_collection(
  value jsonb,
  default_weekly integer,
  default_monthly integer
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  normalized jsonb;
  default_settings jsonb := pg_catalog.jsonb_build_object(
    'weeklyLimit', default_weekly,
    'monthlyLimit', default_monthly
  );
begin
  normalized := pg_catalog.jsonb_build_object('records', '[]'::jsonb, 'settings', default_settings);
  if pg_catalog.jsonb_typeof(value) = 'object' then normalized := normalized || value; end if;
  normalized := pg_catalog.jsonb_set(
    normalized,
    '{records}',
    private.normalize_record_array(normalized->'records'),
    true
  );
  normalized := pg_catalog.jsonb_set(
    normalized,
    '{settings}',
    default_settings || case
      when pg_catalog.jsonb_typeof(normalized->'settings') = 'object' then normalized->'settings'
      else '{}'::jsonb
    end,
    true
  );
  return normalized;
end;
$$;

create or replace function private.clamp_sync_timestamps(value jsonb, anchor timestamptz)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  key_name text;
  child jsonb;
  item jsonb;
  parsed timestamptz;
  text_value text;
  event_time numeric;
  anchor_millis numeric := pg_catalog.floor(pg_catalog.date_part('epoch', anchor) * 1000);
  result jsonb;
begin
  if value is null then return null; end if;

  if pg_catalog.jsonb_typeof(value) = 'string' then
    text_value := value #>> '{}';
    if text_value ~ '^(habit-record-(delete|live):|sync-(delete|live):).+:[0-9]+$' then
      event_time := (pg_catalog.substring(text_value, '([0-9]+)$'))::numeric;
      if event_time > anchor_millis + 300000 then
        return pg_catalog.to_jsonb(
          pg_catalog.regexp_replace(text_value, '[0-9]+$', anchor_millis::bigint::text)
        );
      end if;
    end if;
    return value;
  end if;

  if pg_catalog.jsonb_typeof(value) = 'array' then
    result := '[]'::jsonb;
    for item in select entry from pg_catalog.jsonb_array_elements(value) entry
    loop
      result := result || pg_catalog.jsonb_build_array(private.clamp_sync_timestamps(item, anchor));
    end loop;
    return result;
  end if;

  if pg_catalog.jsonb_typeof(value) = 'object' then
    result := '{}'::jsonb;
    for key_name, child in
      select object_entry.key, object_entry.value
      from pg_catalog.jsonb_each(value) as object_entry(key, value)
    loop
      if key_name = any (array['updatedAt', 'createdAt', 'archivedAt', 'startedAt', 'endedAt', 'completedAt'])
         and pg_catalog.jsonb_typeof(child) = 'string' then
        parsed := private.try_timestamptz(child #>> '{}');
        if parsed is not null and parsed > anchor + interval '5 minutes' then
          child := pg_catalog.to_jsonb(
            pg_catalog.to_char(anchor at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
          );
        end if;
      else
        child := private.clamp_sync_timestamps(child, anchor);
      end if;
      result := result || pg_catalog.jsonb_build_object(key_name, child);
    end loop;
    return result;
  end if;

  return value;
end;
$$;

create or replace function private.normalize_deletedids(value jsonb, row_data jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  raw jsonb;
  raw_type text;
  legacy_id text;
  entity_kind text;
  item jsonb;
  item_id text;
  linked_id text;
  result jsonb := '[]'::jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'array' then return result; end if;

  for raw in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    raw_type := pg_catalog.jsonb_typeof(raw);
    if raw_type not in ('string', 'number') then continue; end if;
    legacy_id := raw #>> '{}';

    if raw_type = 'string' and legacy_id !~ '^[0-9]+$' then
      result := result || pg_catalog.jsonb_build_array(legacy_id);
      continue;
    end if;
    if legacy_id !~ '^[0-9]+$' then continue; end if;

    for entity_kind, item in
      select 'todo', entry from pg_catalog.jsonb_array_elements(
        coalesce(row_data->'todos', '[]'::jsonb) || coalesce(row_data->'archivedTodos', '[]'::jsonb)
      ) entry
      union all select 'group', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'groups', '[]'::jsonb)) entry
      union all select 'template', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'templates', '[]'::jsonb)) entry
      union all select 'habit', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'habits', '[]'::jsonb)) entry
      union all select 'project', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'projects', '[]'::jsonb)) entry
      union all select 'daily-plan', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'dailyPlans', '[]'::jsonb)) entry
      union all select 'idea', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'ideas', '[]'::jsonb)) entry
      union all select 'focus-session', entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'focusSessions', '[]'::jsonb)) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array(entity_kind || ':' || legacy_id);
      end if;
    end loop;

    for item in select entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'transactions', '[]'::jsonb)) entry
    loop
      item_id := item->>'id';
      linked_id := nullif(item->>'milkteaRecordId', '');
      if linked_id is null and item_id ~* '^mt_.+' then linked_id := pg_catalog.substring(item_id, 4); end if;
      if linked_id is not null
         and private.normalize_legacy_numeric_id(linked_id) = private.normalize_legacy_numeric_id(legacy_id) then
        result := result || pg_catalog.jsonb_build_array(
          'finance:drink-tx:' || private.normalize_legacy_numeric_id(linked_id)
        );
      elsif private.normalize_legacy_numeric_id(item_id) = private.normalize_legacy_numeric_id(legacy_id) then
        result := result || pg_catalog.jsonb_build_array(
          'finance:tx:' || private.normalize_legacy_numeric_id(item_id)
        );
      end if;
    end loop;

    for item in select entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'milktea'->'records', '[]'::jsonb)) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array('drink-record:milktea:' || legacy_id);
      end if;
    end loop;
    for item in select entry from pg_catalog.jsonb_array_elements(coalesce(row_data->'coffee'->'records', '[]'::jsonb)) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array('drink-record:coffee:' || legacy_id);
      end if;
    end loop;
  end loop;

  select coalesce(pg_catalog.jsonb_agg(entry order by entry::text), '[]'::jsonb)
    into result
  from (select distinct entry from pg_catalog.jsonb_array_elements(result) entry) unique_entries;
  return result;
end;
$$;

drop trigger if exists user_data_set_updated_at on public.user_data;
drop function if exists public.set_user_data_updated_at();

create or replace function private.normalize_user_data_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  archived_lower_changed boolean := false;
  archived_camel_changed boolean := false;
  habits_lower_changed boolean := false;
  habits_camel_changed boolean := false;
  normalized_row jsonb;
  anchor timestamptz := pg_catalog.clock_timestamp();
begin
  if tg_op = 'UPDATE' then
    archived_lower_changed := new.archivedtodos is distinct from old.archivedtodos;
    archived_camel_changed := new."archivedTodos" is distinct from old."archivedTodos";
    habits_lower_changed := new.habitrecords is distinct from old.habitrecords;
    habits_camel_changed := new."habitRecords" is distinct from old."habitRecords";
  end if;

  new.todos := private.normalize_record_array(coalesce(new.todos, '[]'::jsonb));
  new.transactions := private.normalize_transactions(coalesce(new.transactions, '[]'::jsonb));
  new.groups := private.normalize_record_array(coalesce(new.groups, '[]'::jsonb));
  new.templates := private.normalize_record_array(coalesce(new.templates, '[]'::jsonb));
  new.habits := private.normalize_record_array(coalesce(new.habits, '[]'::jsonb));
  new.projects := private.normalize_record_array(coalesce(new.projects, '[]'::jsonb));
  new."dailyPlans" := private.normalize_record_array(coalesce(new."dailyPlans", '[]'::jsonb));
  new.ideas := private.normalize_record_array(coalesce(new.ideas, '[]'::jsonb));
  new."focusSessions" := private.normalize_record_array(coalesce(new."focusSessions", '[]'::jsonb));
  new."ideaTags" := coalesce(new."ideaTags", '[]'::jsonb);
  new.milktea := private.normalize_drink_collection(new.milktea, 2, 8);
  new.coffee := private.normalize_drink_collection(new.coffee, 3, 12);

  if tg_op = 'INSERT' or archived_lower_changed = archived_camel_changed then
    new.archivedtodos := private.merge_sync_arrays(
      coalesce(new.archivedtodos, '[]'::jsonb),
      coalesce(new."archivedTodos", '[]'::jsonb)
    );
  elsif archived_lower_changed then
    new.archivedtodos := private.normalize_record_array(coalesce(new.archivedtodos, '[]'::jsonb));
  else
    new.archivedtodos := private.normalize_record_array(coalesce(new."archivedTodos", '[]'::jsonb));
  end if;
  new.archivedtodos := private.normalize_record_array(new.archivedtodos);
  new."archivedTodos" := new.archivedtodos;

  if tg_op = 'INSERT' or habits_lower_changed = habits_camel_changed then
    new.habitrecords := private.merge_sync_json(
      coalesce(new.habitrecords, '{}'::jsonb),
      coalesce(new."habitRecords", '{}'::jsonb)
    );
  elsif habits_lower_changed then
    new.habitrecords := coalesce(new.habitrecords, '{}'::jsonb);
  else
    new.habitrecords := coalesce(new."habitRecords", '{}'::jsonb);
  end if;
  if pg_catalog.jsonb_typeof(new.habitrecords) <> 'object' then new.habitrecords := '{}'::jsonb; end if;
  new."habitRecords" := new.habitrecords;

  new.deletedids := private.normalize_deletedids(
    coalesce(new.deletedids, '[]'::jsonb),
    pg_catalog.to_jsonb(new)
  );
  normalized_row := private.clamp_sync_timestamps(pg_catalog.to_jsonb(new), anchor);
  new := pg_catalog.jsonb_populate_record(new, normalized_row);
  new.updated_at := anchor;
  return new;
end;
$$;

revoke all on function private.try_timestamptz(text) from public, anon, authenticated;
revoke all on function private.normalize_legacy_numeric_id(text) from public, anon, authenticated;
revoke all on function private.merge_sync_arrays(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.merge_sync_json(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_record_array(jsonb) from public, anon, authenticated;
revoke all on function private.normalize_transactions(jsonb) from public, anon, authenticated;
revoke all on function private.normalize_drink_collection(jsonb, integer, integer) from public, anon, authenticated;
revoke all on function private.clamp_sync_timestamps(jsonb, timestamptz) from public, anon, authenticated;
revoke all on function private.normalize_deletedids(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_user_data_row() from public, anon, authenticated;

create trigger user_data_normalize_before_write
before insert or update on public.user_data
for each row execute function private.normalize_user_data_row();

-- Run every existing row through exactly the same contract used for future writes.
update public.user_data set updated_at = updated_at;

alter table public.user_data
  alter column todos set default '[]'::jsonb,
  alter column todos set not null,
  alter column transactions set default '[]'::jsonb,
  alter column transactions set not null,
  alter column groups set default '[]'::jsonb,
  alter column groups set not null,
  alter column templates set default '[]'::jsonb,
  alter column templates set not null,
  alter column archivedtodos set default '[]'::jsonb,
  alter column archivedtodos set not null,
  alter column habits set default '[]'::jsonb,
  alter column habits set not null,
  alter column habitrecords set default '{}'::jsonb,
  alter column habitrecords set not null,
  alter column projects set default '[]'::jsonb,
  alter column projects set not null,
  alter column "archivedTodos" set default '[]'::jsonb,
  alter column "archivedTodos" set not null,
  alter column "habitRecords" set default '{}'::jsonb,
  alter column "habitRecords" set not null,
  alter column milktea set not null,
  alter column "dailyPlans" set default '[]'::jsonb,
  alter column "dailyPlans" set not null,
  alter column coffee set not null,
  alter column deletedids set default '[]'::jsonb,
  alter column deletedids set not null,
  alter column ideas set default '[]'::jsonb,
  alter column ideas set not null,
  alter column "ideaTags" set default '[]'::jsonb,
  alter column "ideaTags" set not null,
  alter column "focusSessions" set default '[]'::jsonb,
  alter column "focusSessions" set not null;

alter table public.user_data drop constraint if exists user_data_sync_shapes;
alter table public.user_data add constraint user_data_sync_shapes check (
  pg_catalog.jsonb_typeof(todos) = 'array'
  and pg_catalog.jsonb_typeof(transactions) = 'array'
  and pg_catalog.jsonb_typeof(groups) = 'array'
  and pg_catalog.jsonb_typeof(templates) = 'array'
  and pg_catalog.jsonb_typeof(archivedtodos) = 'array'
  and pg_catalog.jsonb_typeof(habits) = 'array'
  and pg_catalog.jsonb_typeof(habitrecords) = 'object'
  and pg_catalog.jsonb_typeof(projects) = 'array'
  and pg_catalog.jsonb_typeof("archivedTodos") = 'array'
  and pg_catalog.jsonb_typeof("habitRecords") = 'object'
  and pg_catalog.jsonb_typeof(milktea) = 'object'
  and pg_catalog.jsonb_typeof("dailyPlans") = 'array'
  and pg_catalog.jsonb_typeof(coffee) = 'object'
  and pg_catalog.jsonb_typeof(deletedids) = 'array'
  and pg_catalog.jsonb_typeof(ideas) = 'array'
  and pg_catalog.jsonb_typeof("ideaTags") = 'array'
  and pg_catalog.jsonb_typeof("focusSessions") = 'array'
  and archivedtodos = "archivedTodos"
  and habitrecords = "habitRecords"
);

alter table public.user_data enable row level security;
revoke all on table public.user_data from public, anon, authenticated;
grant select, insert, update on table public.user_data to authenticated;

drop policy if exists user_data_select_own on public.user_data;
drop policy if exists user_data_insert_own on public.user_data;
drop policy if exists user_data_update_own on public.user_data;

create policy user_data_select_own on public.user_data
  for select to authenticated using ((select auth.uid()) = id);
create policy user_data_insert_own on public.user_data
  for insert to authenticated with check ((select auth.uid()) = id);
create policy user_data_update_own on public.user_data
  for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'user_data'
  ) then
    alter publication supabase_realtime add table public.user_data;
  end if;
end;
$$;
