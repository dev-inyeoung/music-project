-- Save another user's post into my archive, and promote a save to my own post.

create function public.save_entry(
  p_source_entry_id uuid, p_place_name text default null,
  p_place_lat float8 default null, p_place_lng float8 default null
) returns public.entries
language plpgsql security definer set search_path = '' as $$
declare
  v_src public.entries;
  v_key text;
  v_row public.entries;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_src from public.entries where id = p_source_entry_id;
  if not found or not public.entry_visible_to(v_src, auth.uid()) then
    raise exception 'entry_not_found';
  end if;
  if v_src.user_id = auth.uid() then
    raise exception 'cannot_save_own';
  end if;
  select group_key into v_key from public.songs where id = v_src.song_id;
  if exists (
    select 1 from public.entries e join public.songs s on s.id = e.song_id
     where e.user_id = auth.uid() and e.status <> 'deleted' and s.group_key = v_key
  ) then
    raise exception 'already_in_archive';
  end if;
  insert into public.entries (user_id, song_id, listened_at, place_name, place_lat, place_lng,
                              visibility, kind, source_entry_id)
  values (auth.uid(), v_src.song_id, now(), public.norm_text(p_place_name), p_place_lat, p_place_lng,
          'private', 'save', v_src.id)
  returning * into v_row;
  return v_row;
end $$;

create function public.promote_save(
  p_entry_id uuid, p_visibility public.entry_visibility, p_comment text,
  p_place_name text, p_place_lat float8, p_place_lng float8
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
  if v_row.kind = 'post' then
    raise exception 'already_posted';
  end if;
  update public.entries
     set kind = 'post', visibility = p_visibility, posted_at = now(),
         comment = public.norm_text(p_comment), place_name = public.norm_text(p_place_name),
         place_lat = p_place_lat, place_lng = p_place_lng
   where id = p_entry_id
   returning * into v_row;
  return v_row;
end $$;

revoke execute on function public.save_entry(uuid, text, float8, float8) from public, anon;
revoke execute on function public.promote_save(uuid, public.entry_visibility, text, text, float8, float8) from public, anon;
grant execute on function public.save_entry(uuid, text, float8, float8) to authenticated;
grant execute on function public.promote_save(uuid, public.entry_visibility, text, text, float8, float8) to authenticated;
