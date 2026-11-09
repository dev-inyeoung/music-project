-- Archive queries. SECURITY INVOKER; restricted explicitly to the caller's own entries.

create type public.archive_item as (
  entry_id uuid,
  kind public.entry_kind,
  song_id text,
  song_title text,
  song_artist text,
  artwork_url text,
  listened_at timestamptz,
  place_name text,
  place_lat float8,
  place_lng float8,
  comment text,
  visibility public.entry_visibility,
  source_author_name text
);

create function public.place_key(p_name text, p_lat float8, p_lng float8) returns text
language sql immutable set search_path = '' as $$
  select case when p_lat is not null and p_lng is not null
              then p_name || '@' || round(p_lat::numeric, 4)::text || ',' || round(p_lng::numeric, 4)::text
              else 'name:' || p_name end
$$;

create function public.archive_month(p_month date, p_tz text default 'Asia/Seoul')
returns setof public.archive_item
language plpgsql stable set search_path = '' as $$
declare
  v_start timestamptz;
  v_end timestamptz;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  v_start := date_trunc('month', p_month)::timestamp at time zone p_tz;
  v_end := (date_trunc('month', p_month) + interval '1 month')::timestamp at time zone p_tz;
  return query
    select e.id, e.kind, s.id, s.title, s.artist, s.artwork_url,
           e.listened_at, e.place_name, e.place_lat, e.place_lng, e.comment,
           e.visibility, sp.display_name
      from public.entries e
      join public.songs s on s.id = e.song_id
      left join public.entries se on se.id = e.source_entry_id
      left join public.profiles sp on sp.id = se.user_id
     where e.user_id = auth.uid() and e.status <> 'deleted'
       and e.listened_at >= v_start and e.listened_at < v_end
     order by e.listened_at desc, e.created_at desc, e.id;
end $$;

create function public.my_places()
returns table(place_key text, place_name text, place_lat float8, place_lng float8,
              entry_count int, latest_artwork_url text)
language plpgsql stable set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  return query
    with mine as (
      select public.place_key(e.place_name, e.place_lat, e.place_lng) as k,
             e.place_name as n, e.place_lat as lat, e.place_lng as lng,
             s.artwork_url as art, e.listened_at, e.created_at
        from public.entries e
        join public.songs s on s.id = e.song_id
       where e.user_id = auth.uid() and e.status <> 'deleted' and e.place_name is not null
    )
    select m.k, (array_agg(m.n order by m.listened_at desc nulls last, m.created_at desc))[1],
           (array_agg(m.lat order by m.listened_at desc nulls last, m.created_at desc))[1],
           (array_agg(m.lng order by m.listened_at desc nulls last, m.created_at desc))[1],
           count(*)::int,
           (array_agg(m.art order by m.listened_at desc nulls last, m.created_at desc))[1]
      from mine m
     group by m.k
     order by count(*) desc, 2;
end $$;

create function public.entries_at_place(p_place_key text)
returns setof public.archive_item
language plpgsql stable set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  return query
    select e.id, e.kind, s.id, s.title, s.artist, s.artwork_url,
           e.listened_at, e.place_name, e.place_lat, e.place_lng, e.comment,
           e.visibility, sp.display_name
      from public.entries e
      join public.songs s on s.id = e.song_id
      left join public.entries se on se.id = e.source_entry_id
      left join public.profiles sp on sp.id = se.user_id
     where e.user_id = auth.uid() and e.status <> 'deleted' and e.place_name is not null
       and public.place_key(e.place_name, e.place_lat, e.place_lng) = p_place_key
     order by e.listened_at desc nulls last, e.created_at desc, e.id;
end $$;

revoke execute on function public.place_key(text, float8, float8) from public, anon;
revoke execute on function public.archive_month(date, text) from public, anon;
revoke execute on function public.my_places() from public, anon;
revoke execute on function public.entries_at_place(text) from public, anon;
grant execute on function public.place_key(text, float8, float8) to authenticated;
grant execute on function public.archive_month(date, text) to authenticated;
grant execute on function public.my_places() to authenticated;
grant execute on function public.entries_at_place(text) to authenticated;
