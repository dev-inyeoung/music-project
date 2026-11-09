begin;
create extension if not exists pgtap with schema extensions;
select plan(2);
select has_function('tests', 'create_user', array['text']);
select isnt(tests.create_user('alice'), null, 'creates user');
select * from finish();
rollback;
