-- Account deletion. Tombstoning lives in one place: a BEFORE DELETE trigger on profiles, which
-- fires whenever the profile goes away (delete_my_account, an operator deleting the auth user in
-- the dashboard, or any other cascade from auth.users). It erases personal data while keeping the
-- song-spread graph intact; afterwards the FK sets entries.user_id (and reports.reporter) null.
create function public.tombstone_profile_entries() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.entries
     set status = 'deleted', comment = null, place_name = null,
         place_lat = null, place_lng = null, listened_at = null
   where user_id = old.id and status <> 'deleted';
  return old;
end $$;

create trigger profiles_tombstone_entries
  before delete on public.profiles
  for each row execute function public.tombstone_profile_entries();

revoke execute on function public.tombstone_profile_entries() from public, anon, authenticated;

-- Deletes the caller's auth user; the cascade to profiles runs the tombstone trigger above.
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  delete from auth.users where id = v_uid;
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
