-- Local-only test helpers. Not for production.
create schema if not exists tests;

create or replace function tests.create_user(p_handle text) returns uuid
language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          p_handle || '@test.local', '{}'::jsonb, '{}'::jsonb, now(), now());
  -- profile row is created by the on_auth_user_created trigger
  update public.profiles set handle = p_handle, display_name = p_handle where id = v_id;
  return v_id;
end $$;

create or replace function tests.as_user(p_id uuid) returns void
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_id, 'role', 'authenticated')::text, true);
end $$;

create or replace function tests.as_service() returns void
language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
end $$;

create or replace function tests.make_friends(a uuid, b uuid) returns void
language plpgsql as $$
begin
  insert into public.friendships (user_low, user_high, status, requested_by)
  values (least(a, b), greatest(a, b), 'accepted', a);
end $$;

create or replace function tests.song(p_id text, p_isrc text default null) returns text
language plpgsql as $$
declare
  v_key text;
begin
  insert into public.songs (id, isrc, title, artist)
  values (p_id, p_isrc, 'Title ' || p_id, 'Artist')
  returning group_key into v_key;
  return v_key;
end $$;

-- p_vis is text (cast at call time) so this file loads before entry_visibility exists.
create or replace function tests.post(p_user uuid, p_song text, p_vis text default 'friends') returns uuid
language plpgsql as $$
declare
  v_id uuid;
begin
  perform tests.as_user(p_user);
  select id into v_id from public.create_post(p_song, now(), null, null, null, null, p_vis::public.entry_visibility);
  perform tests.as_service();
  return v_id;
end $$;

grant usage on schema tests to anon, authenticated;
grant execute on all functions in schema tests to anon, authenticated;
