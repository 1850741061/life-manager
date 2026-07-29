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

  -- Habit check-in maps use epoch numbers. Numeric comparison is required here:
  -- lexical JSON comparison would incorrectly rank 9 above 10.
  if pg_catalog.jsonb_typeof(left_value) = 'number'
     and pg_catalog.jsonb_typeof(right_value) = 'number' then
    if (left_value #>> '{}')::numeric >= (right_value #>> '{}')::numeric then
      return left_value;
    end if;
    return right_value;
  end if;

  if pg_catalog.jsonb_typeof(left_value) = 'boolean'
     and pg_catalog.jsonb_typeof(right_value) = 'boolean' then
    return pg_catalog.to_jsonb((left_value #>> '{}')::boolean or (right_value #>> '{}')::boolean);
  end if;

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

revoke all on function private.merge_sync_json(jsonb, jsonb) from public, anon, authenticated;
