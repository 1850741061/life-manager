-- Harden the shared row contract against stale clients and malformed JSON.
-- This migration is shared byte-for-byte by all four applications.
-- Production migration version: 20260718144551.

create or replace function private.sync_record_time(item jsonb)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    private.try_timestamptz(item->>'updatedAt'),
    private.try_timestamptz(item->>'archivedAt'),
    private.try_timestamptz(item->>'createdAt'),
    private.try_timestamptz(item->>'completedAt'),
    private.try_timestamptz(item->>'endedAt'),
    private.try_timestamptz(item->>'endTime'),
    private.try_timestamptz(item->>'startedAt'),
    private.try_timestamptz(item->>'startTime'),
    '-infinity'::timestamptz
  );
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
    if pg_catalog.jsonb_typeof(item) <> 'object'
       or pg_catalog.jsonb_typeof(item->'id') not in ('string', 'number')
       or pg_catalog.btrim(coalesce(item->>'id', '')) = '' then
      item_key := 'json:' || pg_catalog.md5(item::text);
      if not (by_key ? item_key) then
        by_key := by_key || pg_catalog.jsonb_build_object(item_key, item);
      end if;
      continue;
    end if;

    item_key := pg_catalog.concat('id:', item->>'id');
    existing := by_key->item_key;
    if existing is null then
      by_key := by_key || pg_catalog.jsonb_build_object(item_key, item);
      continue;
    end if;

    item_time := private.sync_record_time(item);
    existing_time := private.sync_record_time(existing);
    if item_time > existing_time or (item_time = existing_time and item::text > existing::text) then
      by_key := by_key || pg_catalog.jsonb_build_object(item_key, existing || item);
    else
      by_key := by_key || pg_catalog.jsonb_build_object(item_key, item || existing);
    end if;
  end loop;

  select coalesce(pg_catalog.jsonb_agg(entry.value order by entry.key), '[]'::jsonb)
    into result
  from pg_catalog.jsonb_each(by_key) entry;
  return result;
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
  existing jsonb;
  merged jsonb;
  item_key text;
  position_text text;
  next_position integer := 0;
  timestamp_value text;
  item_time timestamptz;
  existing_time timestamptz;
  positions jsonb := '{}'::jsonb;
  result jsonb := '[]'::jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'array' then return result; end if;

  for item in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    if pg_catalog.jsonb_typeof(item) <> 'object'
       or pg_catalog.jsonb_typeof(item->'id') not in ('string', 'number')
       or pg_catalog.btrim(coalesce(item->>'id', '')) = '' then
      continue;
    end if;

    if not (item ? 'updatedAt')
       or private.try_timestamptz(item->>'updatedAt') is null
       or (
         item->>'updatedAt' = '1970-01-01T00:00:00.000Z'
         and coalesce(item->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$'
       ) then
      timestamp_value := coalesce(
        case when private.try_timestamptz(item->>'createdAt') is not null then item->>'createdAt' end,
        case when private.try_timestamptz(item->>'archivedAt') is not null then item->>'archivedAt' end,
        case when private.try_timestamptz(item->>'completedAt') is not null then item->>'completedAt' end,
        case when private.try_timestamptz(item->>'endedAt') is not null then item->>'endedAt' end,
        case when private.try_timestamptz(item->>'endTime') is not null then item->>'endTime' end,
        case when private.try_timestamptz(item->>'startedAt') is not null then item->>'startedAt' end,
        case when private.try_timestamptz(item->>'startTime') is not null then item->>'startTime' end,
        case
          when coalesce(item->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$'
            then (item->>'date') || 'T00:00:00.000Z'
        end,
        '1970-01-01T00:00:00.000Z'
      );
      item := pg_catalog.jsonb_set(item, '{updatedAt}', pg_catalog.to_jsonb(timestamp_value), true);
    end if;

    item_key := pg_catalog.concat('id:', item->>'id');
    position_text := positions->>item_key;
    if position_text is null then
      positions := positions || pg_catalog.jsonb_build_object(item_key, next_position);
      result := result || pg_catalog.jsonb_build_array(item);
      next_position := next_position + 1;
      continue;
    end if;

    existing := result->(position_text::integer);
    item_time := private.sync_record_time(item);
    existing_time := private.sync_record_time(existing);
    if item_time > existing_time or (item_time = existing_time and item::text > existing::text) then
      merged := existing || item;
    else
      merged := item || existing;
    end if;
    result := pg_catalog.jsonb_set(result, array[position_text], merged, false);
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
    if pg_catalog.jsonb_typeof(item->'amount') = 'string'
       and coalesce(item->>'amount', '') ~ '^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$' then
      begin
        item := pg_catalog.jsonb_set(
          item,
          '{amount}',
          pg_catalog.to_jsonb((item->>'amount')::numeric),
          true
        );
      exception when others then
        null;
      end;
    end if;
    if not (item ? 'createdAt') then
      item := pg_catalog.jsonb_set(item, '{createdAt}', item->'updatedAt', true);
    end if;
    result := result || pg_catalog.jsonb_build_array(item);
  end loop;
  return result;
end;
$$;

create or replace function private.normalize_string_array(value jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(tag) order by tag), '[]'::jsonb)
  from (
    select distinct entry #>> '{}' as tag
    from pg_catalog.jsonb_array_elements(
      case when pg_catalog.jsonb_typeof(value) = 'array' then value else '[]'::jsonb end
    ) entry
    where pg_catalog.jsonb_typeof(entry) = 'string'
      and pg_catalog.btrim(entry #>> '{}') <> ''
  ) unique_tags;
$$;

create or replace function private.normalize_limit(value jsonb, fallback integer)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
begin
  if pg_catalog.jsonb_typeof(value) = 'number' then return value; end if;
  if pg_catalog.jsonb_typeof(value) = 'string'
     and coalesce(value #>> '{}', '') ~ '^[-+]?[0-9]+$' then
    begin
      return pg_catalog.to_jsonb((value #>> '{}')::numeric);
    exception when others then
      return pg_catalog.to_jsonb(fallback);
    end;
  end if;
  return pg_catalog.to_jsonb(fallback);
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
  settings jsonb;
  default_settings jsonb := pg_catalog.jsonb_build_object(
    'weeklyLimit', default_weekly,
    'monthlyLimit', default_monthly
  );
begin
  normalized := pg_catalog.jsonb_build_object('records', '[]'::jsonb, 'settings', default_settings);
  if pg_catalog.jsonb_typeof(value) = 'object' then normalized := normalized || value; end if;

  settings := case
    when pg_catalog.jsonb_typeof(normalized->'settings') = 'object' then normalized->'settings'
    else '{}'::jsonb
  end;
  settings := default_settings || settings;
  settings := pg_catalog.jsonb_set(
    settings, '{weeklyLimit}', private.normalize_limit(settings->'weeklyLimit', default_weekly), true
  );
  settings := pg_catalog.jsonb_set(
    settings, '{monthlyLimit}', private.normalize_limit(settings->'monthlyLimit', default_monthly), true
  );

  normalized := pg_catalog.jsonb_set(
    normalized, '{records}', private.normalize_record_array(normalized->'records'), true
  );
  normalized := pg_catalog.jsonb_set(normalized, '{settings}', settings, true);
  return normalized;
end;
$$;

create or replace function private.jsonb_array_or_empty(value jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when pg_catalog.jsonb_typeof(value) = 'array' then value else '[]'::jsonb end;
$$;

create or replace function private.deletedid_source_row(old_data jsonb, new_data jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'todos',
      private.jsonb_array_or_empty(old_data->'todos')
      || private.jsonb_array_or_empty(new_data->'todos'),
    'archivedTodos',
      private.jsonb_array_or_empty(old_data->'archivedtodos')
      || private.jsonb_array_or_empty(old_data->'archivedTodos')
      || private.jsonb_array_or_empty(new_data->'archivedtodos')
      || private.jsonb_array_or_empty(new_data->'archivedTodos'),
    'transactions',
      private.jsonb_array_or_empty(old_data->'transactions')
      || private.jsonb_array_or_empty(new_data->'transactions'),
    'groups',
      private.jsonb_array_or_empty(old_data->'groups')
      || private.jsonb_array_or_empty(new_data->'groups'),
    'templates',
      private.jsonb_array_or_empty(old_data->'templates')
      || private.jsonb_array_or_empty(new_data->'templates'),
    'habits',
      private.jsonb_array_or_empty(old_data->'habits')
      || private.jsonb_array_or_empty(new_data->'habits'),
    'projects',
      private.jsonb_array_or_empty(old_data->'projects')
      || private.jsonb_array_or_empty(new_data->'projects'),
    'dailyPlans',
      private.jsonb_array_or_empty(old_data->'dailyPlans')
      || private.jsonb_array_or_empty(new_data->'dailyPlans'),
    'ideas',
      private.jsonb_array_or_empty(old_data->'ideas')
      || private.jsonb_array_or_empty(new_data->'ideas'),
    'focusSessions',
      private.jsonb_array_or_empty(old_data->'focusSessions')
      || private.jsonb_array_or_empty(new_data->'focusSessions'),
    'milktea', pg_catalog.jsonb_build_object(
      'records',
      private.jsonb_array_or_empty(old_data#>'{milktea,records}')
      || private.jsonb_array_or_empty(new_data#>'{milktea,records}')
    ),
    'coffee', pg_catalog.jsonb_build_object(
      'records',
      private.jsonb_array_or_empty(old_data#>'{coffee,records}')
      || private.jsonb_array_or_empty(new_data#>'{coffee,records}')
    )
  );
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
    legacy_id := pg_catalog.btrim(raw #>> '{}');
    if legacy_id = '' then continue; end if;

    if raw_type = 'string' and legacy_id !~ '^[0-9]+$' then
      result := result || pg_catalog.jsonb_build_array(legacy_id);
      continue;
    end if;
    if legacy_id !~ '^[0-9]+$' then continue; end if;

    for entity_kind, item in
      select 'todo', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'todos') || private.jsonb_array_or_empty(row_data->'archivedTodos')) entry
      union all select 'group', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'groups')) entry
      union all select 'template', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'templates')) entry
      union all select 'habit', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'habits')) entry
      union all select 'project', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'projects')) entry
      union all select 'daily-plan', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'dailyPlans')) entry
      union all select 'idea', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'ideas')) entry
      union all select 'focus-session', entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'focusSessions')) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array(entity_kind || ':' || legacy_id);
      end if;
    end loop;

    for item in select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'transactions')) entry
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

    for item in select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'milktea'->'records')) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array('drink-record:milktea:' || legacy_id);
      end if;
    end loop;
    for item in select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'coffee'->'records')) entry
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

create or replace function private.clamp_sync_tombstone_timestamps(value jsonb, anchor timestamptz)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  raw jsonb;
  raw_text text;
  event_time numeric;
  anchor_millis numeric := pg_catalog.floor(pg_catalog.date_part('epoch', anchor) * 1000);
  result jsonb := '[]'::jsonb;
begin
  for raw in
    select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(value)) entry
  loop
    if pg_catalog.jsonb_typeof(raw) = 'string' then
      raw_text := raw #>> '{}';
      if raw_text ~ '^(habit-record-(delete|live):|sync-(delete|live):).+:[0-9]+$' then
        event_time := (pg_catalog.substring(raw_text, '([0-9]+)$'))::numeric;
        if event_time > anchor_millis + 300000 then
          raw := pg_catalog.to_jsonb(
            pg_catalog.regexp_replace(raw_text, '[0-9]+$', anchor_millis::bigint::text)
          );
        end if;
      end if;
    end if;
    result := result || pg_catalog.jsonb_build_array(raw);
  end loop;
  return result;
end;
$$;

create or replace function private.compact_sync_tombstones(value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  raw jsonb;
  raw_text text;
  parts text[];
  event_key text;
  event_time numeric;
  is_delete boolean;
  existing jsonb;
  ordinary jsonb := '{}'::jsonb;
  events jsonb := '{}'::jsonb;
  result jsonb;
begin
  for raw in
    select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(value)) entry
  loop
    if pg_catalog.jsonb_typeof(raw) <> 'string' then continue; end if;
    raw_text := raw #>> '{}';

    parts := pg_catalog.regexp_match(
      raw_text,
      '^habit-record-(delete|live):(.+):([0-9]{4}-[0-9]{2}-[0-9]{2}):([0-9]+)$'
    );
    if parts is not null then
      event_key := 'habit-record:' || parts[2] || ':' || parts[3];
      event_time := parts[4]::numeric;
      is_delete := parts[1] = 'delete';
    else
      parts := pg_catalog.regexp_match(raw_text, '^sync-(delete|live):(.+):([0-9]+)$');
      if parts is null then
        ordinary := ordinary || pg_catalog.jsonb_build_object(raw_text, raw);
        continue;
      end if;
      event_key := 'sync:' || parts[2];
      event_time := parts[3]::numeric;
      is_delete := parts[1] = 'delete';
    end if;

    existing := events->event_key;
    if existing is null
       or event_time > (existing->>'time')::numeric
       or (
         event_time = (existing->>'time')::numeric
         and is_delete
         and not (existing->>'isDelete')::boolean
       ) then
      events := events || pg_catalog.jsonb_build_object(
        event_key,
        pg_catalog.jsonb_build_object('raw', raw, 'time', event_time, 'isDelete', is_delete)
      );
    end if;
  end loop;

  for raw in select entry.value->'raw' from pg_catalog.jsonb_each(events) entry
  loop
    ordinary := ordinary || pg_catalog.jsonb_build_object(raw #>> '{}', raw);
  end loop;

  select coalesce(pg_catalog.jsonb_agg(entry.value order by entry.key), '[]'::jsonb)
    into result
  from pg_catalog.jsonb_each(ordinary) entry;
  return result;
end;
$$;

create or replace function private.tombstone_contains(value jsonb, needle text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select exists (
    select 1
    from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(value)) entry
    where entry #>> '{}' = needle
  );
$$;

create or replace function private.filter_entity_records(value jsonb, entity_kind text, deletedids jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  item_id text;
  result jsonb := '[]'::jsonb;
begin
  for item in select entry from pg_catalog.jsonb_array_elements(private.normalize_record_array(value)) entry
  loop
    item_id := item->>'id';
    if private.tombstone_contains(deletedids, entity_kind || ':' || item_id)
       or private.tombstone_contains(deletedids, item_id) then
      continue;
    end if;
    result := result || pg_catalog.jsonb_build_array(item);
  end loop;
  return result;
end;
$$;

create or replace function private.filter_transactions(value jsonb, deletedids jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  item_id text;
  normalized_id text;
  linked_id text;
  result jsonb := '[]'::jsonb;
begin
  for item in select entry from pg_catalog.jsonb_array_elements(private.normalize_transactions(value)) entry
  loop
    item_id := item->>'id';
    normalized_id := private.normalize_legacy_numeric_id(item_id);
    linked_id := nullif(item->>'milkteaRecordId', '');
    if linked_id is null and item_id ~* '^mt_.+' then linked_id := pg_catalog.substring(item_id, 4); end if;

    if (
      linked_id is not null and (
        private.tombstone_contains(
          deletedids,
          'finance:drink-tx:' || private.normalize_legacy_numeric_id(linked_id)
        )
        or private.tombstone_contains(deletedids, private.normalize_legacy_numeric_id(linked_id))
      )
    ) or private.tombstone_contains(deletedids, 'finance:tx:' || normalized_id)
      or private.tombstone_contains(deletedids, normalized_id) then
      continue;
    end if;

    result := result || pg_catalog.jsonb_build_array(item);
  end loop;
  return result;
end;
$$;

create or replace function private.filter_drink_collection(
  value jsonb,
  drink_type text,
  deletedids jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  item_id text;
  records jsonb := '[]'::jsonb;
  result jsonb := value;
begin
  for item in
    select entry from pg_catalog.jsonb_array_elements(
      private.jsonb_array_or_empty(value->'records')
    ) entry
  loop
    item_id := item->>'id';
    if private.tombstone_contains(deletedids, 'drink-record:' || drink_type || ':' || item_id)
       or private.tombstone_contains(deletedids, 'drink-record:' || item_id)
       or private.tombstone_contains(deletedids, item_id) then
      continue;
    end if;
    records := records || pg_catalog.jsonb_build_array(item);
  end loop;
  return pg_catalog.jsonb_set(result, '{records}', records, true);
end;
$$;

create or replace function private.reconcile_todo_collections(active_value jsonb, archived_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  active_items jsonb := private.normalize_record_array(active_value);
  archived_items jsonb := private.normalize_record_array(archived_value);
  active_item jsonb;
  archived_item jsonb;
  merged_item jsonb;
  active_time timestamptz;
  archived_time timestamptz;
  active_result jsonb := '[]'::jsonb;
  archived_result jsonb := '[]'::jsonb;
begin
  for active_item in select entry from pg_catalog.jsonb_array_elements(active_items) entry
  loop
    archived_item := null;
    select entry into archived_item
    from pg_catalog.jsonb_array_elements(archived_items) entry
    where entry->>'id' = active_item->>'id'
    limit 1;

    if archived_item is null then
      active_result := active_result || pg_catalog.jsonb_build_array(active_item - 'archivedAt');
      continue;
    end if;

    active_time := private.sync_record_time(active_item);
    archived_time := private.sync_record_time(archived_item);
    if active_time >= archived_time then
      merged_item := (archived_item || active_item) - 'archivedAt';
      active_result := active_result || pg_catalog.jsonb_build_array(merged_item);
    end if;
  end loop;

  for archived_item in select entry from pg_catalog.jsonb_array_elements(archived_items) entry
  loop
    active_item := null;
    select entry into active_item
    from pg_catalog.jsonb_array_elements(active_items) entry
    where entry->>'id' = archived_item->>'id'
    limit 1;

    if active_item is null then
      merged_item := archived_item;
    else
      active_time := private.sync_record_time(active_item);
      archived_time := private.sync_record_time(archived_item);
      if archived_time <= active_time then continue; end if;
      merged_item := active_item || archived_item;
    end if;

    if not (merged_item ? 'archivedAt') then
      merged_item := pg_catalog.jsonb_set(
        merged_item,
        '{archivedAt}',
        merged_item->'updatedAt',
        true
      );
    end if;
    archived_result := archived_result || pg_catalog.jsonb_build_array(merged_item);
  end loop;

  return pg_catalog.jsonb_build_object(
    'todos', active_result,
    'archivedTodos', archived_result
  );
end;
$$;

create or replace function private.normalize_habit_records(
  records jsonb,
  habits jsonb,
  deletedids jsonb,
  anchor timestamptz
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  habit_id text;
  dates jsonb;
  date_key text;
  stamp jsonb;
  raw jsonb;
  raw_text text;
  delete_prefix text;
  live_prefix text;
  record_time numeric;
  delete_time numeric;
  live_time numeric;
  candidate_time numeric;
  winning_live numeric;
  anchor_millis numeric := pg_catalog.floor(pg_catalog.date_part('epoch', anchor) * 1000);
  normalized_dates jsonb;
  result jsonb := '{}'::jsonb;
begin
  if pg_catalog.jsonb_typeof(records) <> 'object' then return result; end if;

  for habit_id, dates in select entry.key, entry.value from pg_catalog.jsonb_each(records) entry
  loop
    if pg_catalog.jsonb_typeof(dates) <> 'object'
       or not exists (
         select 1
         from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(habits)) habit(value)
         where habit.value->>'id' = habit_id
       ) then
      continue;
    end if;

    normalized_dates := '{}'::jsonb;
    for date_key, stamp in select entry.key, entry.value from pg_catalog.jsonb_each(dates) entry
    loop
      if date_key !~ '^\d{4}-\d{2}-\d{2}$'
         or pg_catalog.jsonb_typeof(stamp) <> 'number' then
        continue;
      end if;

      record_time := (stamp #>> '{}')::numeric;
      if record_time < 0 then record_time := 0; end if;
      if record_time > anchor_millis + 300000 then record_time := anchor_millis; end if;
      delete_time := 0;
      live_time := 0;
      delete_prefix := 'habit-record-delete:' || habit_id || ':' || date_key || ':';
      live_prefix := 'habit-record-live:' || habit_id || ':' || date_key || ':';

      for raw in
        select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(deletedids)) entry
      loop
        if pg_catalog.jsonb_typeof(raw) <> 'string' then continue; end if;
        raw_text := raw #>> '{}';
        if pg_catalog.left(raw_text, pg_catalog.length(delete_prefix)) = delete_prefix
           and pg_catalog.substring(raw_text, pg_catalog.length(delete_prefix) + 1) ~ '^[0-9]+$' then
          candidate_time := pg_catalog.substring(
            raw_text,
            pg_catalog.length(delete_prefix) + 1
          )::numeric;
          if candidate_time > delete_time then delete_time := candidate_time; end if;
        elsif pg_catalog.left(raw_text, pg_catalog.length(live_prefix)) = live_prefix
           and pg_catalog.substring(raw_text, pg_catalog.length(live_prefix) + 1) ~ '^[0-9]+$' then
          candidate_time := pg_catalog.substring(
            raw_text,
            pg_catalog.length(live_prefix) + 1
          )::numeric;
          if candidate_time > live_time then live_time := candidate_time; end if;
        end if;
      end loop;

      if record_time >= live_time then
        winning_live := record_time;
      else
        winning_live := live_time;
      end if;
      if private.tombstone_contains(
           deletedids,
           'habit-record:' || habit_id || ':' || date_key
         ) and live_time = 0 then
        continue;
      end if;
      if delete_time > 0 and delete_time >= winning_live then continue; end if;
      if winning_live > 0 then
        normalized_dates := normalized_dates || pg_catalog.jsonb_build_object(
          date_key,
          pg_catalog.to_jsonb(winning_live)
        );
      end if;
    end loop;
    result := result || pg_catalog.jsonb_build_object(habit_id, normalized_dates);
  end loop;
  return result;
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
  result jsonb;
begin
  if value is null then return null; end if;
  if pg_catalog.jsonb_typeof(value) = 'string' then return value; end if;

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
      if key_name = 'deletedids' then
        child := private.compact_sync_tombstones(
          private.clamp_sync_tombstone_timestamps(child, anchor)
        );
      elsif key_name = any (
        array[
          'updatedAt', 'createdAt', 'archivedAt', 'startedAt', 'endedAt',
          'startTime', 'endTime', 'completedAt'
        ]
      ) and pg_catalog.jsonb_typeof(child) = 'string' then
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

create or replace function private.sync_record_array_is_valid(value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  item_key text;
  seen jsonb := '{}'::jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'array' then return false; end if;
  for item in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    if pg_catalog.jsonb_typeof(item) <> 'object'
       or pg_catalog.jsonb_typeof(item->'id') not in ('string', 'number')
       or pg_catalog.btrim(coalesce(item->>'id', '')) = '' then
      return false;
    end if;
    item_key := pg_catalog.concat('id:', item->>'id');
    if seen ? item_key then return false; end if;
    seen := seen || pg_catalog.jsonb_build_object(item_key, true);
  end loop;
  return true;
end;
$$;

create or replace function private.sync_string_array_is_valid(value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
  item_key text;
  seen jsonb := '{}'::jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'array' then return false; end if;
  for item in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    if pg_catalog.jsonb_typeof(item) <> 'string'
       or pg_catalog.btrim(item #>> '{}') = '' then
      return false;
    end if;
    item_key := item #>> '{}';
    if seen ? item_key then return false; end if;
    seen := seen || pg_catalog.jsonb_build_object(item_key, true);
  end loop;
  return true;
end;
$$;

create or replace function private.sync_habit_records_are_valid(value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  dates jsonb;
  date_key text;
  stamp jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'object' then return false; end if;
  for dates in select entry.value from pg_catalog.jsonb_each(value) entry
  loop
    if pg_catalog.jsonb_typeof(dates) <> 'object' then return false; end if;
    for date_key, stamp in select entry.key, entry.value from pg_catalog.jsonb_each(dates) entry
    loop
      if date_key !~ '^\d{4}-\d{2}-\d{2}$'
         or pg_catalog.jsonb_typeof(stamp) <> 'number' then
        return false;
      end if;
    end loop;
  end loop;
  return true;
end;
$$;

create or replace function private.sync_transactions_are_valid(value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
begin
  if not private.sync_record_array_is_valid(value) then return false; end if;
  for item in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    if pg_catalog.jsonb_typeof(item->'amount') is distinct from 'number' then return false; end if;
  end loop;
  return true;
end;
$$;

create or replace function private.sync_drink_is_valid(value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  return (pg_catalog.jsonb_typeof(value) is not distinct from 'object')
    and private.sync_record_array_is_valid(value->'records')
    and (pg_catalog.jsonb_typeof(value->'settings') is not distinct from 'object')
    and (pg_catalog.jsonb_typeof(value#>'{settings,weeklyLimit}') is not distinct from 'number')
    and (pg_catalog.jsonb_typeof(value#>'{settings,monthlyLimit}') is not distinct from 'number');
end;
$$;

create or replace function private.sync_tombstones_are_valid(value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
begin
  if pg_catalog.jsonb_typeof(value) <> 'array' then return false; end if;
  for item in select entry from pg_catalog.jsonb_array_elements(value) entry
  loop
    if pg_catalog.jsonb_typeof(item) <> 'string'
       or pg_catalog.btrim(item #>> '{}') = '' then
      return false;
    end if;
  end loop;
  return value = private.compact_sync_tombstones(value);
end;
$$;

create or replace function private.sync_todo_collections_do_not_overlap(
  active_value jsonb,
  archived_value jsonb
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select not exists (
    select 1
    from pg_catalog.jsonb_array_elements(
      private.jsonb_array_or_empty(active_value)
    ) active_item(value)
    join pg_catalog.jsonb_array_elements(
      private.jsonb_array_or_empty(archived_value)
    ) archived_item(value)
      on active_item.value->>'id' = archived_item.value->>'id'
  );
$$;

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
  raw_old jsonb := '{}'::jsonb;
  source_row jsonb;
  tombstone_input jsonb;
  todo_collections jsonb;
  normalized_row jsonb;
  anchor timestamptz := pg_catalog.clock_timestamp();
begin
  if tg_op = 'UPDATE' then
    raw_old := pg_catalog.to_jsonb(old);
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
  new."ideaTags" := private.normalize_string_array(coalesce(new."ideaTags", '[]'::jsonb));
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
  todo_collections := private.reconcile_todo_collections(new.todos, new.archivedtodos);
  new.todos := todo_collections->'todos';
  new.archivedtodos := todo_collections->'archivedTodos';
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

  source_row := private.deletedid_source_row(raw_old, pg_catalog.to_jsonb(new));
  tombstone_input := private.jsonb_array_or_empty(new.deletedids);
  if tg_op = 'UPDATE' then
    -- Entity tombstones are monotonic. Versioned live/delete events are reduced
    -- by compact_sync_tombstones, so stale clients cannot erase a newer event.
    tombstone_input := private.jsonb_array_or_empty(old.deletedids) || tombstone_input;
  end if;
  new.deletedids := private.normalize_deletedids(tombstone_input, source_row);
  new.deletedids := private.compact_sync_tombstones(
    private.clamp_sync_tombstone_timestamps(new.deletedids, anchor)
  );

  new.todos := private.filter_entity_records(new.todos, 'todo', new.deletedids);
  new.archivedtodos := private.filter_entity_records(new.archivedtodos, 'todo', new.deletedids);
  new."archivedTodos" := new.archivedtodos;
  new.transactions := private.filter_transactions(new.transactions, new.deletedids);
  new.groups := private.filter_entity_records(new.groups, 'group', new.deletedids);
  new.templates := private.filter_entity_records(new.templates, 'template', new.deletedids);
  new.habits := private.filter_entity_records(new.habits, 'habit', new.deletedids);
  new.projects := private.filter_entity_records(new.projects, 'project', new.deletedids);
  new."dailyPlans" := private.filter_entity_records(new."dailyPlans", 'daily-plan', new.deletedids);
  new.ideas := private.filter_entity_records(new.ideas, 'idea', new.deletedids);
  new."focusSessions" := private.filter_entity_records(
    new."focusSessions", 'focus-session', new.deletedids
  );
  new.milktea := private.filter_drink_collection(new.milktea, 'milktea', new.deletedids);
  new.coffee := private.filter_drink_collection(new.coffee, 'coffee', new.deletedids);

  new.habitrecords := private.normalize_habit_records(
    new.habitrecords,
    new.habits,
    new.deletedids,
    anchor
  );
  new."habitRecords" := new.habitrecords;

  normalized_row := private.clamp_sync_timestamps(pg_catalog.to_jsonb(new), anchor);
  new := pg_catalog.jsonb_populate_record(new, normalized_row);

  if tg_op = 'UPDATE'
     and (pg_catalog.to_jsonb(new) - 'updated_at') = (pg_catalog.to_jsonb(old) - 'updated_at') then
    new.updated_at := old.updated_at;
  else
    new.updated_at := anchor;
  end if;
  return new;
end;
$$;

-- Canonicalize existing rows before installing the stricter invariant.
update public.user_data set updated_at = updated_at;

alter table public.user_data drop constraint if exists user_data_sync_shapes;
alter table public.user_data add constraint user_data_sync_shapes check (
  private.sync_record_array_is_valid(todos)
  and private.sync_transactions_are_valid(transactions)
  and private.sync_record_array_is_valid(groups)
  and private.sync_record_array_is_valid(templates)
  and private.sync_record_array_is_valid(archivedtodos)
  and private.sync_record_array_is_valid(habits)
  and private.sync_habit_records_are_valid(habitrecords)
  and private.sync_record_array_is_valid(projects)
  and private.sync_record_array_is_valid("archivedTodos")
  and private.sync_habit_records_are_valid("habitRecords")
  and private.sync_drink_is_valid(milktea)
  and private.sync_record_array_is_valid("dailyPlans")
  and private.sync_drink_is_valid(coffee)
  and private.sync_tombstones_are_valid(deletedids)
  and private.sync_record_array_is_valid(ideas)
  and private.sync_string_array_is_valid("ideaTags")
  and private.sync_record_array_is_valid("focusSessions")
  and archivedtodos = "archivedTodos"
  and habitrecords = "habitRecords"
  and private.sync_todo_collections_do_not_overlap(todos, "archivedTodos")
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

revoke all on schema private from public, anon, authenticated;
revoke all on function private.sync_record_time(jsonb) from public, anon, authenticated;
revoke all on function private.merge_sync_arrays(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_record_array(jsonb) from public, anon, authenticated;
revoke all on function private.normalize_transactions(jsonb) from public, anon, authenticated;
revoke all on function private.normalize_string_array(jsonb) from public, anon, authenticated;
revoke all on function private.normalize_limit(jsonb, integer) from public, anon, authenticated;
revoke all on function private.normalize_drink_collection(jsonb, integer, integer) from public, anon, authenticated;
revoke all on function private.jsonb_array_or_empty(jsonb) from public, anon, authenticated;
revoke all on function private.deletedid_source_row(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_deletedids(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.clamp_sync_tombstone_timestamps(jsonb, timestamptz) from public, anon, authenticated;
revoke all on function private.compact_sync_tombstones(jsonb) from public, anon, authenticated;
revoke all on function private.tombstone_contains(jsonb, text) from public, anon, authenticated;
revoke all on function private.filter_entity_records(jsonb, text, jsonb) from public, anon, authenticated;
revoke all on function private.filter_transactions(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.filter_drink_collection(jsonb, text, jsonb) from public, anon, authenticated;
revoke all on function private.reconcile_todo_collections(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_habit_records(jsonb, jsonb, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function private.clamp_sync_timestamps(jsonb, timestamptz) from public, anon, authenticated;
revoke all on function private.sync_record_array_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_string_array_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_habit_records_are_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_transactions_are_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_drink_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_tombstones_are_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_todo_collections_do_not_overlap(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_user_data_row() from public, anon, authenticated;
