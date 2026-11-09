begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset
select tests.create_user('dave') as dave \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.song('s1') as k1 \gset
select tests.song('s2') as k2 \gset
select tests.song('s3') as k3 \gset
select tests.song('s4') as k4 \gset
select tests.song('s5') as k5 \gset
select tests.song('s6') as k6 \gset

select tests.post(:'alice', 's1', 'friends') as a_friends \gset
select tests.post(:'bob', 's2', 'friends') as b_friends \gset
select tests.post(:'bob', 's3', 'private') as b_private \gset
select tests.post(:'carol', 's6', 'public') as c_public \gset
select tests.post(:'carol', 's2', 'friends') as c_friends \gset
select tests.post(:'alice', 's4', 'public') as a_public \gset

-- alice saves carol's public post (a save must not show up in feeds)
select tests.as_user(:'alice') \gset
select id as a_save from public.save_entry(:'c_public') \gset

-- alice hides her own post s4 (hidden must not show up)
select tests.as_service() \gset
update public.entries set status = 'hidden' where id = :'a_public';

select tests.as_user(:'alice') \gset
select is((select array_agg(entry_id order by entry_id) from public.friends_feed()),
  (select array_agg(x order by x) from unnest(array[:'a_friends'::uuid, :'b_friends'::uuid]) x),
  'friends_feed has own and friend posts only');
select is((select count(*)::int from public.friends_feed() where entry_id = :'c_public'), 0,
  'friends_feed excludes non-friend public post');
select is((select array_agg(entry_id) from public.public_feed()), array[:'c_public'::uuid],
  'public_feed has carol public post only (no friends posts, no save, no hidden)');
select is((select count(*)::int from public.friends_feed() where entry_id in (:'a_save', :'a_public')), 0,
  'saves and hidden excluded from friends_feed');
select is((select author_handle::text || '/' || author_name || '/' || song_title from public.friends_feed()
            where entry_id = :'a_friends'), 'alice/alice/Title s1', 'row fields populated');

-- ordering: newest first
select tests.as_service() \gset
update public.entries set posted_at = now() - interval '1 hour' where id = :'a_friends';
update public.entries set posted_at = now() where id = :'b_friends';
select tests.as_user(:'alice') \gset
select is((select array_agg(entry_id) from public.friends_feed()), array[:'b_friends'::uuid, :'a_friends'::uuid],
  'ordered by posted_at desc');

-- blocking removes from public_feed
select tests.as_user(:'carol') \gset
select is((select count(*)::int from public.public_feed()), 1, 'carol public_feed has only her own public post');
select tests.as_service() \gset
insert into public.blocks (blocker, blocked) values (:'dave', :'carol');
select tests.as_user(:'dave') \gset
select is((select count(*)::int from public.public_feed()), 0, 'blocked relation excluded from public_feed');

-- test_feed_cursor_ties: 3 posts with identical posted_at, page size 2
select tests.as_service() \gset
select tests.post(:'bob', 's5', 'friends') as t1 \gset
select tests.post(:'bob', 's1', 'friends') as t2 \gset
select tests.post(:'bob', 's3', 'friends') as t3 \gset
delete from public.entries where id in (:'a_friends', :'b_friends');
update public.entries set posted_at = '2026-01-01 00:00:00+00' where id in (:'t1', :'t2', :'t3');
select tests.as_user(:'alice') \gset
select array_agg(entry_id) as page1, (array_agg(posted_at))[2] as lp, (array_agg(entry_id))[2] as li
  from public.friends_feed(null, null, 2) \gset
select array_agg(entry_id) as page2 from public.friends_feed(:'lp'::timestamptz, :'li'::uuid, 2) \gset
select is((select count(*)::int from unnest(:'page1'::uuid[] || :'page2'::uuid[])), 3, 'test_feed_cursor_ties: 3 total');
select is((select count(distinct x)::int from unnest(:'page1'::uuid[] || :'page2'::uuid[]) x), 3,
  'test_feed_cursor_ties: no duplicates');

-- limit clamp
select is((select count(*)::int from public.friends_feed(null, null, 0)), 1, 'p_limit clamped up to 1');

-- source_author_name
select tests.as_service() \gset
insert into public.entries (user_id, song_id, visibility, kind, source_entry_id)
values (:'bob', 's2', 'private', 'save', :'c_public') returning id as bsave \gset
select tests.as_user(:'bob') \gset
select id as bpromo from public.promote_save(:'bsave', 'friends', null, null, null, null) \gset
select tests.as_user(:'alice') \gset
select is((select source_author_name from public.friends_feed() where entry_id = :'bpromo'), 'carol',
  'source_author_name visible when source visible');
select tests.as_service() \gset
insert into public.blocks (blocker, blocked) values (:'alice', :'carol');
select tests.as_user(:'alice') \gset
select is((select source_author_name is null from public.friends_feed() where entry_id = :'bpromo'), true,
  'source_author_name null when source author blocked');

-- auth
select tests.as_service() \gset
select set_config('role', 'authenticated', true) \gset
select throws_ok('select * from public.friends_feed()', 'P0001', 'not_authenticated', 'friends_feed requires auth');

select * from finish();
rollback;
