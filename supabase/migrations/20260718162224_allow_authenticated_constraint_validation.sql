-- Check constraints execute as the writing role. Expose only their boolean
-- validator entry points; each runs with a fixed empty search_path and invokes
-- the still-private normalization helpers as the function owner.

alter function private.sync_record_array_is_valid(jsonb) security definer;
alter function private.sync_string_array_is_valid(jsonb) security definer;
alter function private.sync_habit_records_are_valid(jsonb) security definer;
alter function private.sync_transactions_are_valid(jsonb) security definer;
alter function private.sync_drink_is_valid(jsonb) security definer;
alter function private.sync_tombstones_are_valid(jsonb) security definer;
alter function private.sync_todo_collections_do_not_overlap(jsonb, jsonb) security definer;
alter function private.sync_json_text_is_safe(jsonb) security definer;
alter function private.sync_json_special_fields_are_safe(jsonb) security definer;

revoke all on function private.sync_record_array_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_string_array_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_habit_records_are_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_transactions_are_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_drink_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_tombstones_are_valid(jsonb) from public, anon, authenticated;
revoke all on function private.sync_todo_collections_do_not_overlap(jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.sync_json_text_is_safe(jsonb) from public, anon, authenticated;
revoke all on function private.sync_json_special_fields_are_safe(jsonb) from public, anon, authenticated;

grant execute on function private.sync_record_array_is_valid(jsonb) to authenticated;
grant execute on function private.sync_string_array_is_valid(jsonb) to authenticated;
grant execute on function private.sync_habit_records_are_valid(jsonb) to authenticated;
grant execute on function private.sync_transactions_are_valid(jsonb) to authenticated;
grant execute on function private.sync_drink_is_valid(jsonb) to authenticated;
grant execute on function private.sync_tombstones_are_valid(jsonb) to authenticated;
grant execute on function private.sync_todo_collections_do_not_overlap(jsonb, jsonb) to authenticated;
grant execute on function private.sync_json_text_is_safe(jsonb) to authenticated;
grant execute on function private.sync_json_special_fields_are_safe(jsonb) to authenticated;

