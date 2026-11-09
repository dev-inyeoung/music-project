-- Friendships and blocks.

create function public.is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  -- R5: authenticated callers may only ask about themselves (auth.uid() null = service context).
  select (auth.uid() is null or auth.uid() = a or auth.uid() = b)
     and exists (
       select 1 from public.blocks
        where (blocker = a and blocked = b) or (blocker = b and blocked = a)
     );
$$;

create function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  -- R5: authenticated callers may only ask about themselves (auth.uid() null = service context).
  select (auth.uid() is null or auth.uid() = a or auth.uid() = b)
     and a is distinct from b
     and exists (
       select 1 from public.friendships f
        where f.user_low = least(a, b) and f.user_high = greatest(a, b)
          and f.status = 'accepted'
     )
     and not public.is_blocked_between(a, b);
$$;

create function public.send_friend_request(p_handle text) returns public.friendship_status
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  v_target uuid;
  v_row public.friendships;
begin
  if v_me is null then
    raise exception 'not_authenticated';
  end if;
  select id into v_target from public.profiles where handle = lower(trim(p_handle));
  if v_target is null then
    raise exception 'user_not_found';
  end if;
  if v_target = v_me then
    raise exception 'cannot_friend_self';
  end if;
  if public.is_blocked_between(v_me, v_target) then
    raise exception 'user_not_found';
  end if;

  insert into public.friendships (user_low, user_high, status, requested_by)
  values (least(v_me, v_target), greatest(v_me, v_target), 'pending', v_me)
  on conflict (user_low, user_high) do nothing;

  select * into v_row from public.friendships
   where user_low = least(v_me, v_target) and user_high = greatest(v_me, v_target)
   for update;

  if v_row.status = 'pending' and v_row.requested_by <> v_me then
    update public.friendships set status = 'accepted'
     where user_low = v_row.user_low and user_high = v_row.user_high;
    return 'accepted'::public.friendship_status;
  end if;
  return v_row.status;
end $$;

create function public.accept_friend_request(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  update public.friendships set status = 'accepted'
   where user_low = least(auth.uid(), p_user) and user_high = greatest(auth.uid(), p_user)
     and status = 'pending' and requested_by = p_user and p_user <> auth.uid();
end $$;

create function public.remove_friend(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  delete from public.friendships
   where user_low = least(auth.uid(), p_user) and user_high = greatest(auth.uid(), p_user);
end $$;

create function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if p_user = auth.uid() then
    raise exception 'cannot_block_self';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'user_not_found';
  end if;
  delete from public.friendships
   where user_low = least(auth.uid(), p_user) and user_high = greatest(auth.uid(), p_user);
  insert into public.blocks (blocker, blocked) values (auth.uid(), p_user)
  on conflict do nothing;
end $$;

create function public.unblock_user(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  delete from public.blocks where blocker = auth.uid() and blocked = p_user;
end $$;

create function public.my_friends()
returns table (user_id uuid, handle extensions.citext, display_name text, star_color text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  return query
    select p.id, p.handle, p.display_name, p.star_color
      from public.friendships f
      join public.profiles p
        on p.id = case when f.user_low = auth.uid() then f.user_high else f.user_low end
     where auth.uid() in (f.user_low, f.user_high)
       and f.status = 'accepted'
       and not public.is_blocked_between(auth.uid(), p.id)
     order by p.handle;
end $$;

create function public.incoming_requests()
returns table (user_id uuid, handle extensions.citext, display_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  return query
    select p.id, p.handle, p.display_name, f.created_at
      from public.friendships f
      join public.profiles p on p.id = f.requested_by
     where auth.uid() in (f.user_low, f.user_high)
       and f.status = 'pending'
       and f.requested_by <> auth.uid()
       and not public.is_blocked_between(auth.uid(), p.id)
     order by f.created_at desc;
end $$;

revoke execute on function public.is_blocked_between(uuid, uuid) from public, anon;
revoke execute on function public.are_friends(uuid, uuid) from public, anon;
revoke execute on function public.send_friend_request(text) from public, anon;
revoke execute on function public.accept_friend_request(uuid) from public, anon;
revoke execute on function public.remove_friend(uuid) from public, anon;
revoke execute on function public.block_user(uuid) from public, anon;
revoke execute on function public.unblock_user(uuid) from public, anon;
revoke execute on function public.my_friends() from public, anon;
revoke execute on function public.incoming_requests() from public, anon;
grant execute on function public.is_blocked_between(uuid, uuid) to authenticated;
grant execute on function public.are_friends(uuid, uuid) to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.accept_friend_request(uuid) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.incoming_requests() to authenticated;

drop policy profiles_select_authenticated on public.profiles;
create policy profiles_select_not_blocked on public.profiles
  for select to authenticated
  using (not public.is_blocked_between(auth.uid(), id));
