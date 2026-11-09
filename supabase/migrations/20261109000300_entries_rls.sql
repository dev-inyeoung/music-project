-- Entries: visibility predicate, RLS, and post RPCs.

-- Single source of truth for "can viewer see entry e". Decides from its arguments;
-- auth.uid() is only used as a caller guard (R5) so it can be reused (e.g. constellation can_open).
create function public.entry_visible_to(e public.entries, viewer uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  -- R5: authenticated callers may only ask about themselves (auth.uid() null = service context).
  select viewer is not null
     and (auth.uid() is null or viewer = auth.uid())
     and (
    (e.user_id = viewer and e.status <> 'deleted')
    or (
      e.status = 'active' and e.kind = 'post'
      and e.user_id is not null  -- orphaned rows (account gone) are never visible to others
      and not public.is_blocked_between(viewer, e.user_id)
      and (
        e.visibility = 'public'
        or (e.visibility = 'friends' and public.are_friends(viewer, e.user_id))
      )
    )
  );
$$;

-- Internal: trim, blank -> null.
create function public.norm_text(t text) returns text
language sql immutable set search_path = '' as $$
  select nullif(trim(t), '');
$$;

create function public.create_post(
  p_song_id text, p_listened_at timestamptz, p_place_name text,
  p_place_lat float8, p_place_lng float8, p_comment text, p_visibility public.entry_visibility
) returns public.entries
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.entries;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  -- song existence: FK; visibility not null: column constraint.
  insert into public.entries (user_id, song_id, listened_at, place_name, place_lat, place_lng,
                              comment, visibility, kind, posted_at)
  values (auth.uid(), p_song_id, coalesce(p_listened_at, now()), public.norm_text(p_place_name),
          p_place_lat, p_place_lng, public.norm_text(p_comment), p_visibility, 'post', now())
  returning * into v_row;
  return v_row;
end $$;

create function public.update_entry(
  p_entry_id uuid, p_listened_at timestamptz, p_place_name text,
  p_place_lat float8, p_place_lng float8, p_comment text,
  p_visibility public.entry_visibility default null
) returns public.entries
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.entries;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_row from public.entries
   where id = p_entry_id and user_id = auth.uid() and status <> 'deleted'
   for update;
  if not found then
    raise exception 'entry_not_found';
  end if;
  if v_row.kind = 'save' and p_visibility is not null then
    raise exception 'save_is_private';
  end if;
  update public.entries
     set listened_at = p_listened_at,
         place_name = public.norm_text(p_place_name),
         place_lat = p_place_lat,
         place_lng = p_place_lng,
         comment = public.norm_text(p_comment),
         visibility = coalesce(p_visibility, visibility)
   where id = p_entry_id
   returning * into v_row;
  return v_row;
end $$;

create function public.delete_entry(p_entry_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  update public.entries
     set status = 'deleted', comment = null, place_name = null,
         place_lat = null, place_lng = null, listened_at = null
   where id = p_entry_id and user_id = auth.uid() and status <> 'deleted';
  if not found then
    raise exception 'entry_not_found';
  end if;
end $$;

revoke execute on function public.entry_visible_to(public.entries, uuid) from public, anon;
revoke execute on function public.norm_text(text) from public, anon, authenticated;
revoke execute on function public.create_post(text, timestamptz, text, float8, float8, text, public.entry_visibility) from public, anon;
revoke execute on function public.update_entry(uuid, timestamptz, text, float8, float8, text, public.entry_visibility) from public, anon;
revoke execute on function public.delete_entry(uuid) from public, anon;
grant execute on function public.entry_visible_to(public.entries, uuid) to authenticated;
grant execute on function public.create_post(text, timestamptz, text, float8, float8, text, public.entry_visibility) to authenticated;
grant execute on function public.update_entry(uuid, timestamptz, text, float8, float8, text, public.entry_visibility) to authenticated;
grant execute on function public.delete_entry(uuid) to authenticated;

create policy entries_select_visible on public.entries
  for select to authenticated
  using (public.entry_visible_to(entries, auth.uid()));
