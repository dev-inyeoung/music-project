-- Constellation: per-song graph of how a song spread between people (source_entry_id edges).
-- SECURITY DEFINER because it walks entries across users. It must never return content
-- columns (comment, place_*, listened_at): only ids, kind, labels, size and can_open.

create function public.get_constellation(p_group_key text, p_focus_entry_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  c_cap constant int := 300;
  v_songs text[];
  v_friends uuid[];
  v_ids uuid[];      -- component members (BFS order)
  v_dist int[];      -- BFS distance from the nearest seed, parallel to v_ids
  v_front uuid[];
  v_depth int := 0;
  v_result jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated';
  end if;

  v_songs := array(select s.id from public.songs s where s.group_key = p_group_key);
  if cardinality(v_songs) = 0 then
    return jsonb_build_object('nodes', '[]'::jsonb, 'edges', '[]'::jsonb, 'truncated', false);
  end if;

  v_friends := array(
    select case when f.user_low = v_me then f.user_high else f.user_low end
      from public.friendships f
     where v_me in (f.user_low, f.user_high) and f.status = 'accepted'
  );

  -- Seeds: my / friends' candidate entries, plus the focus entry if the caller can see it.
  -- Candidate: active save, active friends/public post, or anything with a source or a child
  -- (private posts and hidden/deleted entries only qualify through a link).
  v_ids := array(
    select e.id
      from public.entries e
     where e.song_id = any(v_songs)
       and (e.user_id = v_me
            or (e.user_id = any(v_friends) and public.are_friends(v_me, e.user_id))
            or (e.id = p_focus_entry_id and public.entry_visible_to(e, v_me)))
       and ((e.status = 'active' and (e.kind = 'save' or e.visibility <> 'private'))
            or e.source_entry_id is not null
            or exists (select 1 from public.entries ch where ch.source_entry_id = e.id))
  );
  v_dist := array_fill(0, array[cardinality(v_ids)]);
  v_front := v_ids;

  -- Expand each seed's connected component along source edges in both directions (BFS).
  -- Every linked entry is a candidate by definition, so no further candidate filter is needed.
  while cardinality(v_front) > 0 loop
    v_depth := v_depth + 1;
    v_front := array(
      select distinct q.id from (
        select ch.id from public.entries ch
         where ch.source_entry_id = any(v_front) and ch.song_id = any(v_songs)
        union
        select p.id from public.entries x join public.entries p on p.id = x.source_entry_id
         where x.id = any(v_front) and p.song_id = any(v_songs)
      ) q
      where q.id <> all(v_ids)
    );
    v_ids := v_ids || v_front;
    v_dist := v_dist || array_fill(v_depth, array[cardinality(v_front)]);
  end loop;

  with recursive
  comp as (
    select t.id, t.dist, e as erow, e.user_id, e.kind, e.visibility, e.source_entry_id,
           (e.status <> 'active' or e.user_id is null) as gone,
           coalesce(e.user_id = v_me, false) as is_me,
           (e.user_id is not null and e.user_id <> v_me
            and public.is_blocked_between(v_me, e.user_id)) as blocked,
           (e.user_id = any(v_friends) and public.are_friends(v_me, e.user_id)) as friend
      from unnest(v_ids, v_dist) as t(id, dist)
      join public.entries e on e.id = t.id
  ),
  -- R10: a gone node (deleted/hidden/no user) stays only if it has a non-gone descendant,
  -- i.e. it is an ancestor of some non-gone node. Walk up from every non-gone node.
  live_anc(id) as (
    select c.source_entry_id from comp c where not c.gone and c.source_entry_id is not null
    union
    select c.source_entry_id from comp c join live_anc a on a.id = c.id
     where c.source_entry_id is not null
  ),
  pruned as (
    select c.* from comp c where not c.gone or c.id in (select id from live_anc)
  ),
  -- Blocked people's nodes: keep (anonymous) only when they have a child in the component.
  incl as (
    select c.* from pruned c
     where not c.blocked
        or exists (select 1 from pruned ch where ch.source_entry_id = c.id)
  ),
  incl_edges as (
    select i.source_entry_id as src, i.id as dst
      from incl i where i.source_entry_id in (select id from incl)
  ),
  -- Cap priority: me (and the focus entry) -> friends -> ancestors of those -> the rest by distance.
  prio as (
    select i.id from incl i where i.is_me or i.friend or i.id = p_focus_entry_id
  ),
  anc(id) as (
    select ie.src from incl_edges ie join prio p on p.id = ie.dst
    union
    select ie.src from incl_edges ie join anc a on a.id = ie.dst
  ),
  ranked as (
    select i.*,
           row_number() over (
             order by case when i.is_me or i.id = p_focus_entry_id then 0
                           when i.friend then 1
                           when i.id in (select id from anc) then 2
                           else 3 end,
                      i.dist, i.id) as rn
      from incl i
  ),
  kept as (
    select r.* from ranked r where r.rn <= c_cap
  ),
  kept_edges as (
    select k.source_entry_id as src, k.id as dst
      from kept k where k.source_entry_id in (select id from kept)
  ),
  -- (descendant, ancestor) pairs among kept nodes, for size.
  closure(dst, src) as (
    select ke.dst, ke.src from kept_edges ke
    union all
    select cl.dst, ke.src from closure cl join kept_edges ke on ke.dst = cl.src
  ),
  sizes as (
    select cl.src as id, count(*)::int as size from closure cl group by cl.src
  ),
  -- R8: someone else's post switched to private is anonymous (saves stay named).
  labeled as (
    select k.*,
           (k.gone or k.blocked or not (k.is_me or k.friend)
            or (not k.is_me and k.kind = 'post' and k.visibility = 'private')) as anonymous
      from kept k
  )
  select jsonb_build_object(
    'nodes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'entry_id', l.id,
               'kind', l.kind,
               'is_me', l.is_me,
               'is_friend', l.friend and not l.anonymous,
               'anonymous', l.anonymous,
               'gone', l.gone,
               'user_id', case when l.anonymous then null else l.user_id end,
               'display_name', case when l.anonymous then null else pr.display_name end,
               'star_color', case when l.anonymous then null else pr.star_color end,
               'size', coalesce(s.size, 0),
               -- R9: gray (anonymous) stars never open, even if RLS would allow it.
               'can_open', (l.is_me or not l.anonymous) and public.entry_visible_to(l.erow, v_me)
             ) order by l.dist, l.id)
        from labeled l
        left join sizes s on s.id = l.id
        left join public.profiles pr on pr.id = l.user_id
    ), '[]'::jsonb),
    'edges', coalesce((
      select jsonb_agg(jsonb_build_object('from', ke.src, 'to', ke.dst) order by ke.src, ke.dst)
        from kept_edges ke
    ), '[]'::jsonb),
    'truncated', (select count(*) from incl) > c_cap
  ) into v_result;

  return v_result;
end $$;

revoke execute on function public.get_constellation(text, uuid) from public, anon;
grant execute on function public.get_constellation(text, uuid) to authenticated;
