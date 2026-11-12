begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset
select tests.create_user('dave') as dave \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.song('s1', 'ISRC1') as s1key \gset
select tests.song('s1b', 'ISRC1') as s1bkey \gset
select tests.song('s2', 'ISRC2') as s2key \gset
insert into public.blocks (blocker, blocked) values (:'alice', :'dave');

select tests.post(:'alice', 's1', 'friends') as p_friends \gset
select tests.post(:'alice', 's1b', 'friends') as p_friends_b \gset
select tests.post(:'alice', 's2', 'public') as p_public \gset
select tests.post(:'bob', 's2', 'friends') as p_bob \gset

-- bob saves alice's friends post
select tests.as_user(:'bob') \gset
select kind::text = 'save' and visibility::text = 'private' and source_entry_id = :'p_friends'::uuid
       and user_id = :'bob' and song_id = 's1' and listened_at = now() as ok_save, id as save_id
  from public.save_entry(:'p_friends', ' Cafe ', 37.5, 127.0) \gset
select ok(:'ok_save'::boolean, 'bob saves alice friends post as private save');
select is((select place_name from entries where id = :'save_id'), 'Cafe', 'place_name normalized');

-- stranger cannot save
select tests.as_user(:'carol') \gset
select throws_ok(format('select public.save_entry(%L)', :'p_friends'), 'P0001', 'entry_not_found',
  'stranger cannot save friends post');
-- test_cannot_save_from_blocked
select tests.as_user(:'dave') \gset
select throws_ok(format('select public.save_entry(%L)', :'p_public'), 'P0001', 'entry_not_found',
  'test_cannot_save_from_blocked');
-- unknown source
select throws_ok(format('select public.save_entry(%L)', gen_random_uuid()), 'P0001', 'entry_not_found',
  'unknown source');
-- own
select tests.as_user(:'alice') \gset
select throws_ok(format('select public.save_entry(%L)', :'p_friends'), 'P0001', 'cannot_save_own',
  'cannot save own post');
-- test_save_same_song_twice (same ISRC, different entry)
select tests.as_user(:'bob') \gset
select throws_ok(format('select public.save_entry(%L)', :'p_friends_b'), 'P0001', 'already_in_archive',
  'test_save_same_song_twice');
select throws_ok(format('select public.save_entry(%L)', :'p_friends'), 'P0001', 'already_in_archive',
  'same source twice');
-- bob already has own post of s2 -> already_in_archive
select throws_ok(format('select public.save_entry(%L)', :'p_public'), 'P0001', 'already_in_archive',
  'own post of same song blocks save');

-- not authenticated
select tests.as_service() \gset
select throws_ok(format('select public.save_entry(%L)', :'p_friends'), 'P0001', 'not_authenticated',
  'save_entry requires auth');
select set_config('role', 'authenticated', true) \gset
select throws_ok(format('select public.promote_save(%L, %L, null, null, null, null)', :'save_id', 'friends'),
  'P0001', 'not_authenticated', 'promote_save requires auth');

-- alice cannot see bob's save
select tests.as_user(:'alice') \gset
select is((select count(*)::int from entries where id = :'save_id'), 0, 'save content is private');
select throws_ok(format('select public.promote_save(%L, %L, null, null, null, null)', :'save_id', 'friends'),
  'P0001', 'entry_not_found', 'cannot promote others save');

-- promote
select tests.as_user(:'bob') \gset
select kind::text = 'post' and visibility::text = 'friends' and source_entry_id = :'p_friends'::uuid
       and posted_at = now() and comment = '좋다' and place_name is null as ok_promo
  from public.promote_save(:'save_id', 'friends', ' 좋다 ', ' ', null, null) \gset
select ok(:'ok_promo'::boolean, 'promote_save makes a post keeping source');
select tests.as_user(:'alice') \gset
select is((select count(*)::int from entries where id = :'save_id' and source_entry_id = :'p_friends'), 1,
  'alice sees promoted post');
select tests.as_user(:'bob') \gset
select throws_ok(format('select public.promote_save(%L, %L, null, null, null, null)', :'save_id', 'public'),
  'P0001', 'already_posted', 'already posted');

-- chain A->B->C: bob saves nothing new; use a public promoted post
select tests.as_service() \gset
insert into entries (user_id, song_id, visibility, kind, source_entry_id)
values (:'bob', 's2', 'private', 'save', :'p_public') returning id as save2 \gset
select tests.as_user(:'bob') \gset
select id as promoted2 from public.promote_save(:'save2', 'public', null, null, null, null) \gset
select tests.as_user(:'carol') \gset
select is((select source_entry_id from public.save_entry(:'promoted2')), :'promoted2'::uuid,
  'carol saves bob promoted public post (chain)');

select * from finish();
rollback;
