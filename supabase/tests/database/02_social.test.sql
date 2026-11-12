begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset

-- request + accept
select tests.as_user(:'alice');
select is(public.send_friend_request('bob'), 'pending'::friendship_status, 'alice -> bob is pending');
select is(public.send_friend_request('bob'), 'pending'::friendship_status, 'repeat request is idempotent');
select throws_ok($$select public.send_friend_request('alice')$$, 'P0001', 'cannot_friend_self', 'cannot friend self');
select throws_ok($$select public.send_friend_request('nobody')$$, 'P0001', 'user_not_found', 'unknown handle');

-- requester cannot accept their own request
select public.accept_friend_request(:'bob');
select tests.as_service();
select is((select status from friendships where user_low = least(:'alice'::uuid, :'bob') and user_high = greatest(:'alice'::uuid, :'bob')),
  'pending'::friendship_status, 'requester accepting own request leaves pending');

select tests.as_user(:'bob');
select is((select count(*)::int from public.incoming_requests() where user_id = :'alice'), 1, 'bob sees incoming request');
select public.accept_friend_request(:'alice');
select ok(public.are_friends(:'alice', :'bob'), 'accepted -> are_friends');
select is((select count(*)::int from public.my_friends() where user_id = :'alice' and handle = 'alice'), 1, 'my_friends lists alice');

-- simultaneous requests resolve to accepted
select tests.as_user(:'alice');
select public.send_friend_request('carol');
select tests.as_user(:'carol');
select is(public.send_friend_request('alice'), 'accepted'::friendship_status, 'mutual request -> accepted');

-- R5 caller guard: may only ask about yourself
select tests.as_user(:'bob');
select ok(not public.are_friends(:'alice', :'carol'), 'third party cannot probe are_friends');
select tests.as_service();
select set_config('request.jwt.claims', '', true);
select ok(public.are_friends(:'alice', :'carol'), 'service context (no auth.uid) sees alice-carol friendship');

-- block
select tests.as_user(:'alice');
select public.block_user(:'bob');
select tests.as_service();
select is((select count(*)::int from friendships where :'bob' in (user_low, user_high)), 0, 'block deletes friendship');
select tests.as_user(:'alice');
select is((select count(*)::int from profiles where id = :'bob'), 0, 'blocked profile hidden from blocker');
select throws_ok($$select public.send_friend_request('bob')$$, 'P0001', 'user_not_found', 'request to blocked user hides existence');
select tests.as_user(:'bob');
select is((select count(*)::int from profiles where id = :'alice'), 0, 'blocker profile hidden from blocked');
select tests.as_user(:'carol');
select ok(not public.is_blocked_between(:'alice', :'bob'), 'third party cannot probe is_blocked_between');

select * from finish();
rollback;
