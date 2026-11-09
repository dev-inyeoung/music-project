begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

select is(tests.song('1', 'KRA0001'), 'KRA0001', 'group_key uses isrc');
select is(tests.song('2'), 'am:2', 'group_key falls back to am:id');
select tests.song('3', 'KRA0001');
select is((select count(distinct group_key)::int from songs where id in ('1', '3')), 1,
  'same ISRC, different ids share group_key');

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset

select ok(
  (select star_color from profiles where id = :'alice') = any (array[
    '#FFD166','#06D6A0','#EF476F','#118AB2','#A78BFA','#F78C6B',
    '#4CC9F0','#F15BB5','#9BE564','#FF9F1C','#2EC4B6','#E0AAFF']),
  'new user star_color is from palette');

insert into entries (id, user_id, song_id, visibility, kind, posted_at)
values ('00000000-0000-0000-0000-0000000000a1', :'alice', '1', 'friends', 'post', now());

select throws_ok(
  format($f$insert into entries (user_id, song_id, visibility, kind, source_entry_id)
    values (%L, '1', 'friends', 'save', '00000000-0000-0000-0000-0000000000a1')$f$, :'bob'),
  '23514', null, 'save with visibility friends violates check');

select throws_ok(
  format($f$insert into entries (user_id, song_id, visibility, kind, posted_at, place_lat)
    values (%L, '1', 'friends', 'post', now(), 37.5)$f$, :'alice'),
  '23514', null, 'place_lat without place_lng violates check');

select tests.as_user(:'alice'::uuid);
select throws_ok($$select set_profile('민지', '민지')$$, '23514', null, 'test_handle_rejects_non_ascii');
select throws_ok(
  $$insert into entries (user_id, song_id, visibility, kind, posted_at)
    values (auth.uid(), '1', 'friends', 'post', now())$$,
  '42501', null, 'authenticated cannot insert into entries');

select * from finish();
rollback;
