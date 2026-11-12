begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

-- Catalog-wide: no function in schema public is executable by anon (directly or via PUBLIC).
select is(
  (select coalesce(array_agg(p.oid::regprocedure::text order by 1), '{}')
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and has_function_privilege('anon', p.oid, 'execute')),
  '{}'::text[],
  'anon has no EXECUTE on any public function');

-- Trigger functions are not callable by app roles either.
select ok(not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'),
  'authenticated cannot execute handle_new_user');
select ok(not has_function_privilege('authenticated', 'public.tombstone_profile_entries()', 'execute'),
  'authenticated cannot execute tombstone_profile_entries');

select * from finish();
rollback;
