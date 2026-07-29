-- Cross-app sync v4:
-- 1. Heal older deployments that never received the focusSessions column.
-- 2. Keep habit check-in history even when a client does not know the habit
--    definition yet. A later/reinstalled client can then restore that history.
-- 3. Preserve old boolean `true` check-ins as a stable positive version.
-- 4. Retain unmatched generation-one numeric tombstones against resurrection.

alter table public.user_data
  add column if not exists "focusSessions" jsonb not null default '[]'::jsonb;

-- A generation-one client used a bare numeric id as a cross-domain tombstone.
-- v3 converted it to typed tombstones only while a matching record was still
-- present. Retain an unmatched id as a string so an old offline client cannot
-- later re-upload that record and resurrect it.
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
  matched boolean;
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

    matched := false;
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
        matched := true;
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
        matched := true;
      elsif private.normalize_legacy_numeric_id(item_id) = private.normalize_legacy_numeric_id(legacy_id) then
        result := result || pg_catalog.jsonb_build_array(
          'finance:tx:' || private.normalize_legacy_numeric_id(item_id)
        );
        matched := true;
      end if;
    end loop;

    for item in select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'milktea'->'records')) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array('drink-record:milktea:' || legacy_id);
        matched := true;
      end if;
    end loop;
    for item in select entry from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(row_data->'coffee'->'records')) entry
    loop
      if item->>'id' = legacy_id then
        result := result || pg_catalog.jsonb_build_array('drink-record:coffee:' || legacy_id);
        matched := true;
      end if;
    end loop;

    if not matched then
      result := result || pg_catalog.jsonb_build_array(legacy_id);
    end if;
  end loop;

  select coalesce(pg_catalog.jsonb_agg(entry order by entry::text), '[]'::jsonb)
    into result
  from (select distinct entry from pg_catalog.jsonb_array_elements(result) entry) unique_entries;
  return result;
end;
$$;

comment on function private.normalize_deletedids(jsonb, jsonb)
  is 'Normalizes tombstones while retaining unmatched generation-one numeric ids against resurrection.';

revoke all on function private.normalize_deletedids(jsonb, jsonb)
  from public, anon, authenticated;

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

  for habit_id, dates in
    select entry.key, entry.value from pg_catalog.jsonb_each(records) entry
  loop
    -- Do not require habit_id to exist in habits. Different app generations
    -- legitimately know different built-in habits, and deleting the definition
    -- must not silently erase the user's historical check-ins.
    if pg_catalog.jsonb_typeof(dates) <> 'object' then continue; end if;

    normalized_dates := '{}'::jsonb;
    for date_key, stamp in
      select entry.key, entry.value from pg_catalog.jsonb_each(dates) entry
    loop
      if date_key !~ '^\d{4}-\d{2}-\d{2}$' then
        continue;
      end if;

      if pg_catalog.jsonb_typeof(stamp) = 'number' then
        record_time := (stamp #>> '{}')::numeric;
      elsif pg_catalog.jsonb_typeof(stamp) = 'boolean' and stamp = 'true'::jsonb then
        -- Generation-one clients stored check-ins as booleans. Version 1 is
        -- deliberately stable and older than every timestamped tombstone, so
        -- preserving it cannot resurrect a subsequently deleted check-in.
        record_time := 1;
      else
        continue;
      end if;
      if record_time < 0 then record_time := 0; end if;
      if record_time > anchor_millis + 300000 then record_time := anchor_millis; end if;
      delete_time := 0;
      live_time := 0;
      delete_prefix := 'habit-record-delete:' || habit_id || ':' || date_key || ':';
      live_prefix := 'habit-record-live:' || habit_id || ':' || date_key || ':';

      for raw in
        select entry
        from pg_catalog.jsonb_array_elements(private.jsonb_array_or_empty(deletedids)) entry
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

      winning_live := pg_catalog.greatest(record_time, live_time);
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

comment on function private.normalize_habit_records(jsonb, jsonb, jsonb, timestamptz)
  is 'Normalizes habit check-ins without pruning unknown habit ids; tombstones remain authoritative.';

revoke all on function private.normalize_habit_records(jsonb, jsonb, jsonb, timestamptz)
  from public, anon, authenticated;
