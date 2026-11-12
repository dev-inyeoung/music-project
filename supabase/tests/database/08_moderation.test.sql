begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

select tests.create_user('alice') as alice \gset
select tests.create_user('bob') as bob \gset
select tests.create_user('carol') as carol \gset
select tests.create_user('dave') as dave \gset
select tests.create_user('erin') as erin \gset
select tests.make_friends(:'alice', :'bob') \gset
select tests.song('s1') as k1 \gset
select tests.song('s2') as k2 \gset

select tests.post(:'alice', 's1', 'public') as a_post \gset
select tests.post(:'dave', 's2', 'private') as d_private \gset

-- no vault secrets exist: report must still succeed
select tests.as_user(:'bob') \gset
select lives_ok(format($$select public.report_entry(%L, '  spam  ')$$, :'a_post'),
  'report succeeds without vault secrets');
select tests.as_service() \gset
select is((select report_count from public.entries where id = :'a_post'::uuid), 1, 'count is 1 after first report');
select tests.as_user(:'bob') \gset
select tests.as_service() \gset
select is((select reason from public.reports where entry_id = :'a_post'::uuid), 'spam', 'reason is normalized');
select tests.as_user(:'bob') \gset

-- duplicate report is a no-op
select public.report_entry(:'a_post', 'again') \gset
select tests.as_service() \gset
select is((select report_count from public.entries where id = :'a_post'::uuid), 1, 'duplicate report does not increment');
select tests.as_user(:'bob') \gset

-- errors
select throws_ok(format($$select public.report_entry(%L, null)$$, :'d_private'), 'P0001', 'entry_not_found',
  'cannot report an invisible entry');
select tests.as_user(:'alice') \gset
select throws_ok(format($$select public.report_entry(%L, null)$$, :'a_post'), 'P0001', 'entry_not_found',
  'cannot report own entry');
select tests.as_service() \gset
select throws_ok(format($$select public.report_entry(%L, null)$$, :'a_post'), 'P0001', 'not_authenticated',
  'unauthenticated cannot report');

-- third distinct reporter hides the entry
select tests.as_user(:'carol') \gset
select public.report_entry(:'a_post', null) \gset
select is((select status::text from public.entries where id = :'a_post'::uuid), 'active', 'still active at 2 reports');
select tests.as_user(:'dave') \gset
select public.report_entry(:'a_post', null) \gset
select tests.as_service() \gset
select is((select status::text from public.entries where id = :'a_post'::uuid), 'hidden', 'hidden at 3 reports');

select tests.as_user(:'bob') \gset
select is((select count(*)::int from public.friends_feed() where entry_id = :'a_post'), 0, 'hidden entry gone from friends feed');
select is((select count(*)::int from public.entries where id = :'a_post'::uuid), 0, 'hidden entry gone from others RLS select');

-- with secrets present, a report queues an http request
select tests.as_service() \gset
select vault.create_secret('http://example.invalid/notify', 'notify_report_url') \gset
select vault.create_secret('s3cret', 'notify_report_secret') \gset
select tests.post(:'alice', 's2', 'public') as a_post2 \gset
select tests.as_user(:'erin') \gset
select public.report_entry(:'a_post2', 'x') \gset
select tests.as_service() \gset
select is((select count(*)::int from net.http_request_queue where url = 'http://example.invalid/notify'), 1,
  'report queues a notification when secrets exist');

select * from finish();
rollback;
