-- Account deletion: tombstone all of the caller's entries (keeps the song-spread graph intact,
-- erases personal data), then delete the auth user (cascades profile, friendships, blocks;
-- entries.user_id and reports.reporter are set null).
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  update public.entries
     set status = 'deleted', comment = null, place_name = null,
         place_lat = null, place_lng = null, listened_at = null
   where user_id = v_uid and status <> 'deleted';
  delete from auth.users where id = v_uid;
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
