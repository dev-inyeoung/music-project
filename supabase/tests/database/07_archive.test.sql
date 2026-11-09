begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.song('s1') as k1 \gset
select tests.song('s2') as k2 \gset
select tests.song('s3') as k3 \gset
select tests.song('s4') as k4 \gset
select tests.song('s5') as k5 \gset
select tests.song('s6') as k6 \gset
select tests.song('s7') as k7 \gset

select tests.as_user(:'alice') \gset
-- 2026-11-01 00:30 KST == 2026-10-31 15:30 UTC
select id as e_edge from public.create_post('s1', '2026-10-31 15:30+00', 'Cafe', 37.5, 127.0, 'edge', 'private') \gset
select id as e_oct from public.create_post('s2', '2026-10-31 14:30+00', 'Cafe', 37.5, 127.0, null, 'friends') \gset
select id as e_home from public.create_post('s3', '2026-11-05 03:00+00', 'Home', null, null, null, 'friends') \gset
select id as e_office from public.create_post('s4', '2026-11-06 03:00+00', 'Office', null, null, null, 'public') \gset
select id as e_del from public.create_post('s5', '2026-11-07 03:00+00', 'Home', null, null, null, 'public') \gset
select public.delete_entry(:'e_del') \gset
select id as e_home2 from public.create_post('s7', '2026-11-02 03:00+00', 'Home', null, null, null, 'friends') \gset

select tests.as_user(:'bob') \gset
select id as b_post from public.create_post('s6', '2026-11-08 03:00+00', 'Cafe', 37.5, 127.0, null, 'public') \gset
select tests.as_user(:'alice') \gset
select id as a_save from public.save_entry(:'b_post') \gset

-- hidden entries are still in my archive
select tests.as_service() \gset
update public.entries set status = 'hidden' where id = :'e_office';
-- save_entry stamps now(): pin it so no assertion depends on the wall clock
update public.entries set listened_at = '2026-11-09 03:00+00' where id = :'a_save';
update public.songs set artwork_url = 'https://is1-ssl.mzstatic.com/art-s3.jpg' where id = 's3';
update public.songs set artwork_url = 'https://is1-ssl.mzstatic.com/art-s7.jpg' where id = 's7';

select tests.as_user(:'alice') \gset
select ok(exists (select 1 from public.archive_month('2026-11-01') where entry_id = :'e_edge'),
  'KST Nov 1 00:30 is in November');
select ok(exists (select 1 from public.archive_month('2026-11-20') where entry_id = :'e_edge'),
  'any day of the month works');
select ok(not exists (select 1 from public.archive_month('2026-10-15') where entry_id = :'e_edge'),
  'not in October');
select ok(exists (select 1 from public.archive_month('2026-10-15') where entry_id = :'e_oct'),
  'KST Oct 31 23:30 is in October');
select ok(not exists (select 1 from public.archive_month('2026-11-01') where entry_id in (:'e_del', :'b_post')),
  'deleted and others'' entries excluded');
select ok(exists (select 1 from public.archive_month('2026-11-01') where entry_id = :'e_office'),
  'hidden entries included');
select is((select array_agg(entry_id) from public.archive_month('2026-11-01')),
  array[:'a_save'::uuid, :'e_office'::uuid, :'e_home'::uuid, :'e_home2'::uuid, :'e_edge'::uuid],
  'ordered by listened_at desc; saves included');
select is((select source_author_name from public.archive_month('2026-11-01') where entry_id = :'a_save'),
  'bob', 'save carries source author name');
select is((select source_entry_id from public.archive_month('2026-11-01') where entry_id = :'a_save'),
  :'b_post'::uuid, 'save carries source_entry_id');
select is((select group_key from public.archive_month('2026-11-01') where entry_id = :'e_home'),
  :'k3', 'archive item carries group_key');
select is((select status from public.archive_month('2026-11-01') where entry_id = :'e_office'),
  'hidden'::public.entry_status, 'archive item carries status (hidden)');
select is((select group_key || '/' || status || '/' || coalesce(source_entry_id::text, '-')
             from public.entries_at_place('name:Home') where entry_id = :'e_home'),
  :'k3' || '/active/-', 'entries_at_place carries group_key, status, source_entry_id');

select is((select count(*)::int from public.my_places()), 3, 'three distinct places');
select is((select place_name || '/' || entry_count from public.my_places() limit 1), 'Cafe/2',
  'most visited place first');
select is((select entry_count from public.my_places() where place_name = 'Home'), 2,
  'name-only entries group by name; deleted entry not counted');
select ok((select place_lat is null and place_lng is null from public.my_places() where place_name = 'Home'),
  'name-only group has null coordinates');
select is((select latest_artwork_url from public.my_places() where place_name = 'Home'), 'https://is1-ssl.mzstatic.com/art-s3.jpg',
  'latest_artwork_url comes from the most recent entry in the group');
select is((select count(*)::int from public.entries_at_place('name:Home')), 2,
  'entries_at_place for name-only key');
select is((select count(*)::int from public.entries_at_place(public.place_key('Cafe', 37.5, 127.0))), 2,
  'entries_at_place returns only my entries at the place');

select tests.as_user(:'bob') \gset
select is((select count(*)::int from public.archive_month('2026-11-01', 'Asia/Seoul')
                  where entry_id in (:'e_edge', :'e_home', :'e_office')), 0,
  'bob sees none of alice''s entries');

select * from finish();
rollback;
