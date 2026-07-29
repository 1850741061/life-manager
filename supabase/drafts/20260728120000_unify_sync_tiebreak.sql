-- Cross-app sync v5:
-- Make equal-timestamp conflict arbitration independent of the database
-- locale.  The clients compare their canonical JSON strings with an explicit
-- code-unit/bytewise ordering; PostgreSQL text comparison is collation-aware
-- and can choose the opposite winner for non-ASCII values.

create or replace function private.sync_json_is_greater(
  left_value jsonb,
  right_value jsonb
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.convert_to(left_value::text, 'UTF8')
       > pg_catalog.convert_to(right_value::text, 'UTF8');
$$;

revoke all on function private.sync_json_is_greater(jsonb, jsonb)
  from public, anon, authenticated;

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
      case when pg_catalog.jsonb_typeof(left_value) = 'array'
        then left_value else '[]'::jsonb end
    )
    union all
    select value
    from pg_catalog.jsonb_array_elements(
      case when pg_catalog.jsonb_typeof(right_value) = 'array'
        then right_value else '[]'::jsonb end
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
    if item_time > existing_time
       or (item_time = existing_time
           and private.sync_json_is_greater(item, existing)) then
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
    if item_time > existing_time
       or (item_time = existing_time
           and private.sync_json_is_greater(item, existing)) then
      merged := existing || item;
    else
      merged := item || existing;
    end if;
    result := pg_catalog.jsonb_set(result, array[position_text], merged, false);
  end loop;
  return result;
end;
$$;

revoke all on function private.merge_sync_arrays(jsonb, jsonb)
  from public, anon, authenticated;
revoke all on function private.normalize_record_array(jsonb)
  from public, anon, authenticated;

comment on function private.sync_json_is_greater(jsonb, jsonb)
  is 'Locale-independent UTF-8 bytewise tie-break for equal-timestamp sync records.';
