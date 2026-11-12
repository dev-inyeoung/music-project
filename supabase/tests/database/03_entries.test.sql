begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset
select tests.create_user('dave') as dave \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.song('s1') as s1key \gset
insert into public.blocks (blocker, blocked) values (:'alice', :'dave');

select tests.post(:'alice', 's1', 'friends') as p_friends \gset
select tests.post(:'alice', 's1', 'public') as p_public \gset
select tests.post(:'alice', 's1', 'private') as p_private \gset

-- friends visibility
select tests.as_user(:'bob') \gset
select is((select count(*)::int from entries where id = :'p_friends'), 1, 'friend sees friends post');
select is((select count(*)::int from entries where id = :'p_private'), 0, 'friend cannot see private post');
select tests.as_user(:'carol') \gset
select is((select count(*)::int from entries where id = :'p_friends'), 0, 'stranger cannot see friends post');
select is((select count(*)::int from entries where id = :'p_public'), 1, 'stranger sees public post');
select is((select count(*)::int from entries where id = :'p_private'), 0, 'stranger cannot see private post');
select tests.as_user(:'alice') \gset
select is((select count(*)::int from entries where id = :'p_private'), 1, 'owner sees own private post');

-- test_blocked_cannot_read_by_id
select tests.as_user(:'dave') \gset
select is((select count(*)::int from entries where id = :'p_public'), 0, 'test_blocked_cannot_read_by_id');

-- R5 caller guard on entry_visible_to
select tests.as_service() \gset
select row_to_json(e)::text as e_friends from entries e where id = :'p_friends' \gset
select tests.as_user(:'carol') \gset
select ok(not public.entry_visible_to(json_populate_record(null::entries, :'e_friends'::json), :'bob'),
  'third party cannot probe entry_visible_to for another viewer');
select tests.as_user(:'bob') \gset
select ok(public.entry_visible_to(json_populate_record(null::entries, :'e_friends'::json), :'bob'),
  'viewer may ask about themselves');
select tests.as_service() \gset
select set_config('request.jwt.claims', '', true) \gset
select ok(public.entry_visible_to(json_populate_record(null::entries, :'e_friends'::json), :'bob'),
  'service context (no auth.uid) unguarded');

-- anon sees nothing
select tests.as_service() \gset
set local role anon;
select is((select count(*)::int from entries), 0, 'anon sees no entries');
select tests.as_service() \gset

-- hidden posts are visible to the owner only
update entries set status = 'hidden' where id = :'p_public';
select tests.as_user(:'carol') \gset
select is((select count(*)::int from entries where id = :'p_public'), 0, 'hidden post not visible to others');
select tests.as_user(:'alice') \gset
select is((select count(*)::int from entries where id = :'p_public'), 1, 'hidden post visible to owner');
select tests.as_service() \gset
update entries set status = 'active' where id = :'p_public';

-- direct DML denied
select tests.as_user(:'alice') \gset
select throws_ok(
  format($$insert into entries (song_id, visibility, kind, posted_at, user_id) values ('s1', 'public', 'post', now(), %L)$$, :'alice'),
  '42501', null, 'authenticated cannot insert entries directly');

-- test_blank_comment_becomes_null, listened_at defaults to now
select id as p_blank, comment is null as blank_null, listened_at = now() as listened_now,
       posted_at = now() as posted_now, kind = 'post' and user_id = :'alice' as owned_post
  from public.create_post('s1', null, '  ', null, null, '   ', 'friends') \gset
select ok(:'blank_null'::boolean, 'test_blank_comment_becomes_null');
select ok(:'listened_now'::boolean, 'null listened_at becomes now()');
select ok(:'posted_now'::boolean, 'posted_at is now()');
select ok(:'owned_post'::boolean, 'create_post makes a post owned by caller');
select throws_ok($$select public.create_post('s1', now(), null, null, null, null, null)$$,
  '23502', null, 'null visibility rejected');
select throws_ok($$select public.create_post('s1', now(), 'x', 1.0, null, null, 'public')$$,
  '23514', null, 'lat without lng rejected');

-- update_entry
select tests.as_user(:'bob') \gset
select throws_ok(format('select public.update_entry(%L, now(), null, null, null, %L)', :'p_friends', 'hi'),
  'P0001', 'entry_not_found', 'cannot update others entry');
select tests.as_user(:'alice') \gset
select is(
  (select row(comment, place_name, place_lat, visibility)::text
     from public.update_entry(:'p_friends', now(), ' Seoul ', 37.5, 127.0, ' hello ')),
  row('hello', 'Seoul', 37.5::float8, 'friends'::entry_visibility)::text,
  'update replaces fields, trims text, keeps visibility by default');
select is(
  (select row(comment, place_name, place_lat, listened_at, visibility)::text
     from public.update_entry(:'p_friends', null, null, null, null, '  ', 'public')),
  row(null::text, null::text, null::float8, null::timestamptz, 'public'::entry_visibility)::text,
  'null clears fields, visibility updated when given');
select throws_ok(format('select public.update_entry(%L, now(), null, null, null, null)', gen_random_uuid()),
  'P0001', 'entry_not_found', 'unknown entry');

-- save entries cannot change visibility
select tests.as_service() \gset
insert into entries (user_id, song_id, visibility, kind, source_entry_id)
values (:'bob', 's1', 'private', 'save', :'p_public') returning id as p_save \gset
select tests.as_user(:'bob') \gset
select throws_ok(format('select public.update_entry(%L, now(), null, null, null, null, %L)', :'p_save', 'public'),
  'P0001', 'save_is_private', 'save visibility cannot be set');

-- delete_entry
select tests.as_user(:'bob') \gset
select throws_ok(format('select public.delete_entry(%L)', :'p_public'),
  'P0001', 'entry_not_found', 'cannot delete others entry');
select tests.as_user(:'alice') \gset
select public.delete_entry(:'p_public') \gset
select is((select count(*)::int from entries where id = :'p_public'), 0, 'deleted entry hidden from owner');
select tests.as_service() \gset
select ok((select comment is null and place_name is null and place_lat is null and place_lng is null
                  and listened_at is null and status = 'deleted'
             from entries where id = :'p_public'), 'delete scrubs fields and marks deleted');

-- not_authenticated
select set_config('request.jwt.claims', '', true) \gset
set local role authenticated;
select throws_ok($$select public.create_post('s1', now(), null, null, null, null, 'public')$$,
  'P0001', 'not_authenticated', 'create_post requires auth');

select * from finish();
rollback;
