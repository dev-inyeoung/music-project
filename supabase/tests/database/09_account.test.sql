begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset
select tests.create_user('stranger') as stranger \gset
select tests.create_user('dan') as dan \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.make_friends(:'alice', :'carol') \gset
select tests.song('s1', 'ISRC-D1') as gk \gset
select tests.song('s2') as gk2 \gset
select tests.song('s3') as gk3 \gset

select tests.as_user(:'alice') \gset
select id as a from public.create_post('s1', now(), 'Secret Cafe', 37.5, 127.0,
  'ALICE-SECRET', 'public') \gset
select id as a2 from public.create_post('s2', now(), 'Home', 1, 2, 'second', 'private') \gset
select tests.as_user(:'bob') \gset
select id as b from public.save_entry(:'a') \gset
select tests.as_user(:'carol') \gset
select id as c from public.create_post('s3', now(), null, null, null, 'carol', 'public') \gset
select tests.as_user(:'alice') \gset
select id as asave from public.save_entry(:'c') \gset
select public.report_entry(:'c', 'alice reports') \gset
select tests.as_user(:'stranger') \gset
select public.report_entry(:'c', 'stranger reports') \gset

-- guards
select tests.as_service() \gset
select throws_ok('select public.delete_my_account()', 'P0001', 'not_authenticated',
  'delete_my_account requires auth');
select ok(not has_function_privilege('anon', 'public.delete_my_account()', 'execute'),
  'anon cannot execute');
select ok(has_function_privilege('authenticated', 'public.delete_my_account()', 'execute'),
  'authenticated can execute');

-- delete
select tests.as_user(:'alice') \gset
select lives_ok('select public.delete_my_account()', 'alice deletes account');
select tests.as_service() \gset

select is((select count(*)::int from public.profiles where id = :'alice'::uuid), 0, 'profile gone');
select is((select count(*)::int from auth.users where id = :'alice'::uuid), 0, 'auth user gone');
select is((select count(*)::int from public.friendships
            where :'alice'::uuid in (user_low, user_high)), 0, 'friendships gone');
select ok((select user_id is null and status = 'deleted' and comment is null and place_name is null
                  and place_lat is null and place_lng is null and listened_at is null
                  and song_id = 's1' and kind = 'post' and posted_at is not null
             from public.entries where id = :'a'::uuid),
  'public post is an anonymous tombstone');
select ok((select user_id is null and status = 'deleted' and comment is null and listened_at is null
             from public.entries where id = :'a2'::uuid),
  'private post is tombstoned');
select ok((select user_id is null and status = 'deleted' and kind = 'save'
                  and source_entry_id = :'c'::uuid
             from public.entries where id = :'asave'::uuid),
  'alice save is tombstoned, source kept');
select is((select count(*)::int from public.entries where id = :'b'::uuid and user_id = :'bob'::uuid
            and source_entry_id = :'a'::uuid and status = 'active'), 1,
  'bob save intact with source_entry_id');
select is((select count(*)::int from public.reports where reporter is null
            and entry_id = :'c'::uuid), 1, 'alice report kept with null reporter');
select is((select count(*)::int from public.reports where reporter = :'stranger'::uuid), 1,
  'other reports untouched');

-- bob's view
select tests.as_user(:'bob') \gset
select is((select count(*)::int from public.my_friends() where user_id = :'alice'::uuid), 0,
  'alice gone from bob friends');
select public.get_constellation(:'gk') as g \gset
select ok((select (n->>'gone')::boolean and (n->>'anonymous')::boolean
                  and n->'user_id' = 'null'::jsonb
             from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'a'),
  'alice node is gone + anonymous with null user_id');

-- stranger can no longer see the former public post
select tests.as_user(:'stranger') \gset
select is((select count(*)::int from public.entries where id = :'a'::uuid), 0,
  'tombstone invisible to stranger via RLS');

-- Account removed outside the RPC (operator deletes the auth user directly): the profile
-- BEFORE DELETE trigger tombstones the content.
select tests.as_user(:'dan') \gset
select id as dpub from public.create_post('s1', now(), 'Dan Place', 1, 2, 'DAN-SECRET', 'public') \gset
select tests.as_service() \gset
delete from auth.users where id = :'dan'::uuid;
select ok((select user_id is null and status = 'deleted' and comment is null and place_name is null
                  and place_lat is null and place_lng is null and listened_at is null
             from public.entries where id = :'dpub'::uuid),
  'direct auth.users delete tombstones the public post');
select tests.as_user(:'stranger') \gset
select is((select count(*)::int from public.entries where id = :'dpub'::uuid), 0,
  'directly-deleted user''s post invisible to stranger via RLS');

-- Defense in depth: an orphaned row that somehow stayed active is not visible to non-owners.
select tests.as_service() \gset
insert into public.entries (id, user_id, song_id, visibility, kind, posted_at)
values ('00000000-0000-0000-0000-0000000000f1', null, 's1', 'public', 'post', now());
select tests.as_user(:'stranger') \gset
select is((select count(*)::int from public.entries
            where id = '00000000-0000-0000-0000-0000000000f1'), 0,
  'orphaned active public row is not visible');

select tests.as_service() \gset
select ok(not has_function_privilege('authenticated', 'public.tombstone_profile_entries()', 'execute')
          and not has_function_privilege('anon', 'public.tombstone_profile_entries()', 'execute'),
  'tombstone trigger function not executable by app roles');
select ok(exists (select 1 from pg_trigger t where t.tgrelid = 'public.profiles'::regclass
                   and t.tgname = 'profiles_tombstone_entries' and not t.tgisinternal),
  'profiles has the tombstone trigger');

select * from finish();
rollback;
