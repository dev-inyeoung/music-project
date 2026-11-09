begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset
select tests.create_user('dave') as dave \gset
select tests.create_user('eve') as eve \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.make_friends(:'bob', :'carol') \gset
select tests.song('s1', 'ISRC-C1') as gk \gset
select tests.song('s2') as gk2 \gset
select star_color as bob_color from public.profiles where id = :'bob' \gset

-- Chain built through the RPCs: alice A -> bob B (save, promoted) -> carol C (save, promoted
-- to public so it can be saved from) -> dave D (save).
select tests.as_user(:'alice') \gset
select id as a from public.create_post('s1', now(), 'Secret Cafe', 37.5, 127.0,
  'ALICE-SECRET-COMMENT-7f3a', 'friends') \gset
select tests.as_user(:'bob') \gset
select id as b from public.save_entry(:'a') \gset
select public.promote_save(:'b', 'friends', 'bob says hi', null, null, null) \gset
select tests.as_user(:'carol') \gset
select id as c from public.save_entry(:'b') \gset
select public.promote_save(:'c', 'public', null, null, null, null) \gset
select tests.as_user(:'dave') \gset
select id as d from public.save_entry(:'c') \gset

-- auth required
select tests.as_service() \gset
select throws_ok(format('select public.get_constellation(%L)', :'gk'), 'P0001', 'not_authenticated',
  'get_constellation requires auth');
select ok(not has_function_privilege('anon', 'public.get_constellation(text, uuid)', 'execute'),
  'anon cannot execute get_constellation');

select tests.as_user(:'alice') \gset
select public.get_constellation(:'gk') as g \gset

select is(jsonb_array_length(:'g'::jsonb->'nodes'), 4, 'chain: 4 nodes');
select is((select array_agg((x->>'from') || '>' || (x->>'to') order by x->>'from', x->>'to')
             from jsonb_array_elements(:'g'::jsonb->'edges') x),
          (select array_agg(v order by v) from unnest(array[
             :'a' || '>' || :'b', :'b' || '>' || :'c', :'c' || '>' || :'d']) v),
  'chain: edges A>B, B>C, C>D');
select is((select array_agg((n->>'size')::int order by array_position(
              array[:'a', :'b', :'c', :'d'], n->>'entry_id'))
             from jsonb_array_elements(:'g'::jsonb->'nodes') n),
          array[3, 2, 1, 0], 'sizes A=3 B=2 C=1 D=0');
select ok((select bool_and((n->>'anonymous')::boolean and n->'display_name' = 'null'::jsonb
                           and n->'user_id' = 'null'::jsonb and n->'star_color' = 'null'::jsonb
                           and not (n->>'is_friend')::boolean)
             from jsonb_array_elements(:'g'::jsonb->'nodes') n
            where n->>'entry_id' in (:'c', :'d')),
  'carol and dave nodes are anonymous with null name/color/user_id');
select ok((select (n->>'is_friend')::boolean and n->>'star_color' = :'bob_color'
                  and n->>'display_name' = 'bob' and n->>'user_id' = :'bob'
                  and not (n->>'anonymous')::boolean and n->>'kind' = 'post'
             from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'b'),
  'bob B node is friend with bob color');
select ok((select (n->>'is_me')::boolean and not (n->>'anonymous')::boolean and n->>'user_id' = :'alice'
             from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'a'),
  'A node is mine');
select ok(position('ALICE-SECRET-COMMENT-7f3a' in :'g') = 0
          and position('Secret Cafe' in :'g') = 0 and position('bob says hi' in :'g') = 0,
  'test_constellation_no_content');
select is((select array_agg((n->>'can_open')::boolean order by array_position(
              array[:'a', :'b', :'c', :'d'], n->>'entry_id'))
             from jsonb_array_elements(:'g'::jsonb->'nodes') n),
          array[true, true, true, false], 'can_open follows RLS (D is a private save)');
select is((select n->>'kind' from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'d'),
  'save', 'D kind is save');
select is(:'g'::jsonb->'truncated', 'false'::jsonb, 'not truncated');

-- independent records
select tests.as_user(:'bob') \gset
select id as b_indep from public.create_post('s1', now(), null, null, null, null, 'friends') \gset
select tests.post(:'eve', 's1', 'public') as e_pub \gset
select tests.post(:'eve', 's1', 'private') as e_priv \gset
select tests.as_user(:'alice') \gset
select public.get_constellation(:'gk') as g \gset
select ok(exists (select 1 from jsonb_array_elements(:'g'::jsonb->'nodes') n
                   where n->>'entry_id' = :'b_indep' and (n->>'size')::int = 0),
  'bob independent record is a node');
select ok(not exists (select 1 from jsonb_array_elements(:'g'::jsonb->'edges') x
                       where :'b_indep' in (x->>'from', x->>'to')),
  'bob independent record has no edges');
select is(jsonb_array_length(:'g'::jsonb->'edges'), 3, 'still 3 edges');
select ok(not exists (select 1 from jsonb_array_elements(:'g'::jsonb->'nodes') n
                       where n->>'entry_id' = :'e_pub'),
  'eve independent public record is not shown');
select ok(not exists (select 1 from jsonb_array_elements(:'g'::jsonb->'nodes') n
                       where n->>'entry_id' = :'e_priv'),
  'eve independent private record is not shown');
select is(jsonb_array_length(:'g'::jsonb->'nodes'), 5, '5 nodes');

-- focus entry: visible -> seed; not visible -> ignored
select is((select count(*)::int from jsonb_array_elements(
             public.get_constellation(:'gk', :'e_pub')->'nodes') n where n->>'entry_id' = :'e_pub'),
  1, 'visible focus entry becomes a seed');
select is((select count(*)::int from jsonb_array_elements(
             public.get_constellation(:'gk', :'e_priv')->'nodes') n where n->>'entry_id' = :'e_priv'),
  0, 'invisible focus entry is ignored');
select is(jsonb_array_length(public.get_constellation(:'gk2', :'e_pub')->'nodes'), 0,
  'focus entry from another song is ignored');

-- deleted B: gone + anonymous, edges kept
select tests.as_user(:'bob') \gset
select public.delete_entry(:'b') \gset
select tests.as_user(:'alice') \gset
select public.get_constellation(:'gk') as g \gset
select ok((select (n->>'gone')::boolean and (n->>'anonymous')::boolean and not (n->>'is_friend')::boolean
                  and n->'user_id' = 'null'::jsonb and n->'star_color' = 'null'::jsonb
                  and not (n->>'can_open')::boolean
             from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'b'),
  'deleted B is gone and anonymous');
select is(jsonb_array_length(:'g'::jsonb->'edges'), 3, 'edges kept after delete');
select is((select (n->>'size')::int from jsonb_array_elements(:'g'::jsonb->'nodes') n
            where n->>'entry_id' = :'a'), 3, 'A size still 3 after delete');

-- blocking: C has a child -> anonymous; D is a leaf -> excluded
select public.block_user(:'carol') \gset
select public.get_constellation(:'gk') as g \gset
select ok((select (n->>'anonymous')::boolean and n->'user_id' = 'null'::jsonb and not (n->>'can_open')::boolean
             from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'c'),
  'blocked carol C stays anonymous (has child)');
select is(jsonb_array_length(:'g'::jsonb->'nodes'), 5, 'still 5 nodes after blocking carol');
select public.block_user(:'dave') \gset
select public.get_constellation(:'gk') as g \gset
select ok(not exists (select 1 from jsonb_array_elements(:'g'::jsonb->'nodes') n where n->>'entry_id' = :'d'),
  'blocked dave D is excluded (leaf)');
select ok(not exists (select 1 from jsonb_array_elements(:'g'::jsonb->'edges') x where x->>'to' = :'d'),
  'edge C>D removed with D');
select is((select (n->>'size')::int from jsonb_array_elements(:'g'::jsonb->'nodes') n
            where n->>'entry_id' = :'a'), 2, 'A size counts included nodes only');

-- test_constellation_node_cap: 350 saves of A2 by distinct users
select tests.as_user(:'alice') \gset
select id as a2 from public.create_post('s2', now(), null, null, null, null, 'public') \gset
select tests.as_service() \gset
select set_config('tests.a2', :'a2', true) \gset
do $$
declare
  v_src uuid := current_setting('tests.a2')::uuid;
begin
  for i in 1..350 loop
    insert into public.entries (user_id, song_id, visibility, kind, source_entry_id, listened_at)
    values (tests.create_user('cap_' || i), 's2', 'private', 'save', v_src, now());
  end loop;
end $$;
select tests.as_user(:'alice') \gset
select public.get_constellation(:'gk2') as g2 \gset
select ok(jsonb_array_length(:'g2'::jsonb->'nodes') <= 300, 'test_constellation_node_cap: at most 300 nodes');
select is(:'g2'::jsonb->'truncated', 'true'::jsonb, 'test_constellation_node_cap: truncated');
select ok(exists (select 1 from jsonb_array_elements(:'g2'::jsonb->'nodes') n where n->>'entry_id' = :'a2'),
  'test_constellation_node_cap: A included');
select ok(not exists (
            select 1 from jsonb_array_elements(:'g2'::jsonb->'edges') x
             where not exists (select 1 from jsonb_array_elements(:'g2'::jsonb->'nodes') n
                                where n->>'entry_id' = x->>'from')
                or not exists (select 1 from jsonb_array_elements(:'g2'::jsonb->'nodes') n
                                where n->>'entry_id' = x->>'to')),
  'test_constellation_node_cap: edges only among kept nodes');

select * from finish();
rollback;
