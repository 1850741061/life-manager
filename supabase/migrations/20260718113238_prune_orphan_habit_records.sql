create or replace function private.prune_habit_records(records jsonb, habits jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_object_agg(record_entry.key, record_entry.value), '{}'::jsonb)
  from pg_catalog.jsonb_each(
    case when pg_catalog.jsonb_typeof(records) = 'object' then records else '{}'::jsonb end
  ) as record_entry(key, value)
  where exists (
    select 1
    from pg_catalog.jsonb_array_elements(
      case when pg_catalog.jsonb_typeof(habits) = 'array' then habits else '[]'::jsonb end
    ) as habit_entry(value)
    where habit_entry.value->>'id' = record_entry.key
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
  new.habitrecords := private.prune_habit_records(new.habitrecords, new.habits);
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

revoke all on function private.prune_habit_records(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.normalize_user_data_row() from public, anon, authenticated;

update public.user_data set updated_at = updated_at;
