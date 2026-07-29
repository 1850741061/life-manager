-- Enforce a plain-text, attribute-safe contract for the shared JSON payload.
-- The legacy desktop renderers use HTML templates, so active/tag-like markup,
-- unsafe record identifiers, CSS colors, or icon class values must never cross
-- the cloud boundary unchanged.

create or replace function private.sync_text_is_safe(value text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select value is null or not (
    value ~* '<[[:space:]]*/?[[:space:]]*[[:alpha:]!][^>]*>'
    or value ~* '<[[:space:]]*/?[[:space:]]*(script|iframe|object|embed|svg|math|img|video|audio|source|track|body|style|link|meta|base|form|input|button|textarea|select|option|details|marquee)([[:space:]/>]|$)'
  );
$$;

create or replace function private.neutralize_sync_json(value jsonb)
returns jsonb
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  kind text;
  raw text;
  child jsonb;
  key_name text;
  result jsonb;
begin
  if value is null then return 'null'::jsonb; end if;
  kind := pg_catalog.jsonb_typeof(value);

  if kind = 'string' then
    raw := value #>> '{}';
    if private.sync_text_is_safe(raw) then return value; end if;
    return pg_catalog.to_jsonb(
      pg_catalog.replace(
        pg_catalog.replace(raw, '<', '＜'),
        '>',
        '＞'
      )
    );
  end if;

  if kind = 'array' then
    result := '[]'::jsonb;
    for child in select entry from pg_catalog.jsonb_array_elements(value) entry
    loop
      result := result || pg_catalog.jsonb_build_array(private.neutralize_sync_json(child));
    end loop;
    return result;
  end if;

  if kind = 'object' then
    result := '{}'::jsonb;
    for key_name, child in select entry.key, entry.value from pg_catalog.jsonb_each(value) entry
    loop
      result := result || pg_catalog.jsonb_build_object(
        key_name,
        private.neutralize_sync_json(child)
      );
    end loop;
    return result;
  end if;

  return value;
end;
$$;

create or replace function private.sync_json_text_is_safe(value jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select private.neutralize_sync_json(value) = value;
$$;

create or replace function private.sync_json_special_fields_are_safe(value jsonb)
returns boolean
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  kind text;
  key_name text;
  child jsonb;
  raw text;
begin
  if value is null then return true; end if;
  kind := pg_catalog.jsonb_typeof(value);

  if kind = 'array' then
    for child in select entry from pg_catalog.jsonb_array_elements(value) entry
    loop
      if not private.sync_json_special_fields_are_safe(child) then return false; end if;
    end loop;
    return true;
  end if;

  if kind <> 'object' then return true; end if;

  for key_name, child in select entry.key, entry.value from pg_catalog.jsonb_each(value) entry
  loop
    if pg_catalog.jsonb_typeof(child) = 'string' then
      raw := child #>> '{}';

      if (key_name = 'id' or key_name ~ '^[A-Za-z][A-Za-z0-9_]*(Id|ID)$')
         and (
           pg_catalog.btrim(raw) = ''
           or raw !~ '^[A-Za-z0-9_.:-]+$'
         ) then
        return false;
      end if;

      if key_name ~* 'color$'
         and raw !~* '^(#[0-9a-f]{3,8}|(rgb|rgba|hsl|hsla)\([0-9.,%[:space:]+-]+\)|var\(--[a-z0-9_-]+\)|[a-z]+)$' then
        return false;
      end if;

      if key_name ~* 'icon$'
         and raw !~* '^[a-z0-9 _-]+$' then
        return false;
      end if;
    end if;

    if not private.sync_json_special_fields_are_safe(child) then return false; end if;
  end loop;

  return true;
end;
$$;

create or replace function private.sanitize_user_data_content()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.todos := private.neutralize_sync_json(new.todos);
  new.transactions := private.neutralize_sync_json(new.transactions);
  new.groups := private.neutralize_sync_json(new.groups);
  new.templates := private.neutralize_sync_json(new.templates);
  new.archivedtodos := private.neutralize_sync_json(new.archivedtodos);
  new.habits := private.neutralize_sync_json(new.habits);
  new.habitrecords := private.neutralize_sync_json(new.habitrecords);
  new.projects := private.neutralize_sync_json(new.projects);
  new."archivedTodos" := private.neutralize_sync_json(new."archivedTodos");
  new."habitRecords" := private.neutralize_sync_json(new."habitRecords");
  new.milktea := private.neutralize_sync_json(new.milktea);
  new."dailyPlans" := private.neutralize_sync_json(new."dailyPlans");
  new.coffee := private.neutralize_sync_json(new.coffee);
  new.deletedids := private.neutralize_sync_json(new.deletedids);
  new.ideas := private.neutralize_sync_json(new.ideas);
  new."ideaTags" := private.neutralize_sync_json(new."ideaTags");
  new."focusSessions" := private.neutralize_sync_json(new."focusSessions");
  return new;
end;
$$;

drop trigger if exists user_data_content_sanitize_before_write on public.user_data;
create trigger user_data_content_sanitize_before_write
before insert or update on public.user_data
for each row execute function private.sanitize_user_data_content();

alter table public.user_data
  drop constraint if exists user_data_sync_content_safe;

alter table public.user_data
  add constraint user_data_sync_content_safe check (
    private.sync_json_text_is_safe(pg_catalog.jsonb_build_array(
      todos, transactions, groups, templates, archivedtodos, habits,
      habitrecords, projects, "archivedTodos", "habitRecords", milktea,
      "dailyPlans", coffee, deletedids, ideas, "ideaTags", "focusSessions"
    ))
    and private.sync_json_special_fields_are_safe(pg_catalog.jsonb_build_array(
      todos, transactions, groups, templates, archivedtodos, habits,
      habitrecords, projects, "archivedTodos", "habitRecords", milktea,
      "dailyPlans", coffee, deletedids, ideas, "ideaTags", "focusSessions"
    ))
  );

revoke all on function private.sync_text_is_safe(text) from public, anon, authenticated;
revoke all on function private.neutralize_sync_json(jsonb) from public, anon, authenticated;
revoke all on function private.sync_json_text_is_safe(jsonb) from public, anon, authenticated;
revoke all on function private.sync_json_special_fields_are_safe(jsonb) from public, anon, authenticated;
revoke all on function private.sanitize_user_data_content() from public, anon, authenticated;

comment on constraint user_data_sync_content_safe on public.user_data is
  'Shared sync JSON is plain text and contains only attribute-safe IDs, colors, and icons.';


