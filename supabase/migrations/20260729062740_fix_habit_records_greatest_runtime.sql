-- Fix the v4 runtime qualification bug on greatest().
-- PostgreSQL resolves GREATEST as a special built-in, not pg_catalog.greatest.
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

      winning_live := (case when record_time >= live_time then record_time else live_time end);
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
