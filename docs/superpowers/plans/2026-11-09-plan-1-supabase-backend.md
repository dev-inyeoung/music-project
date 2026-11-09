# Plan 1 — Supabase 백엔드 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 음악 기록 앱의 데이터, 공개 범위 규칙(RLS), 피드, 저장/올리기, 별자리, 아카이브, 신고, 계정 삭제를 Supabase(Postgres) 안에 만들고 pgTAP 테스트로 증명한다.

**Architecture:** 모든 쓰기는 `SECURITY DEFINER` RPC로만 한다(테이블에 직접 INSERT/UPDATE/DELETE 권한 없음). 읽기 중 "내용"은 `entries` RLS가 막고, 별자리처럼 "존재"만 드러내는 읽기는 내용 컬럼을 반환하지 않는 `SECURITY DEFINER` 함수가 담당한다. 삭제는 하드 삭제 대신 내용을 비운 tombstone 행으로 남겨 체인을 보존한다.

**Tech Stack:** Supabase CLI, Postgres (Supabase 로컬 스택), pgTAP, pg_net + Vault (신고 알림), Supabase Edge Function (Deno, TypeScript), Resend (이메일).

**Spec:** `docs/superpowers/specs/2026-11-09-music-diary-app-design.md`

**Plan 시리즈:** 이 스펙은 독립적인 하위 시스템 4개로 나눠 계획한다. 이 문서는 1번이다.
1. **Supabase 백엔드** (이 문서)
2. iOS 기반: 로그인, 프로필, 기록하기, 아카이브
3. iOS 피드, 저장, 별자리
4. iOS 친구, 차단, 신고, 계정 삭제 (Apple 토큰 revoke 포함)

## Global Constraints

- 공개 범위 값은 정확히 `private` / `friends` / `public`. 항목 종류는 `post` / `save`.
- `kind = 'save'`이면 `visibility = 'private'`이고 `source_entry_id`가 반드시 있다. 저장은 어떤 피드에도 나오지 않는다.
- 저장 항목의 코멘트와 장소는 항상 본인만 볼 수 있다.
- `visibility = 'private'`인 post는 체인 연결(출처가 있거나 자식이 있음)이 없으면 별자리에 나오지 않는다.
- 별자리 표시 규칙:
  - 친구: 이름과 `star_color`로 표시한다.
  - 친구 아닌 사람, 차단 관계인 사람, 삭제된 기록: 익명 회색 별로 표시한다.
  - 크기는 그 노드의 하위 노드 수다. 익명 노드도 센다.
- 같은 노래 판정: `group_key = coalesce(isrc, 'am:' || apple_music_id)`.
- 신고 3회 누적 시 `status = 'hidden'`. 신고마다 운영자 이메일 알림을 보낸다.
- 전체 피드는 최신순(`posted_at desc, id desc`)이다.
- 계정 삭제 시 프로필, 코멘트, 장소는 지우고 연결 구조는 익명 tombstone으로 남긴다.
- 테이블에 대한 `authenticated` / `anon`의 INSERT/UPDATE/DELETE 권한은 없다. 쓰기는 RPC로만 한다.

## Review Focus

1. **같은 시각에 올라온 글의 페이지 경계**: 커서가 `(posted_at, id)` 쌍이라 중복이나 누락이 없어야 한다. → Task 6 `test_feed_cursor_ties`
2. **이미 아카이브에 있는 곡을 또 저장**: 같은 사람이 한 별자리에 두 번 나타나면 안 된다. 그래서 `already_in_archive` 오류를 낸다. → Task 5 `test_save_same_song_twice`
3. **공백만 있는 코멘트나 장소 이름**: null로 저장되어야 하고 빈 말풍선이 생기면 안 된다. → Task 4 `test_blank_comment_becomes_null`
4. **차단한 사람의 기록 id를 직접 아는 경우**: RLS로 조회와 저장이 모두 막혀야 한다. → Task 4 `test_blocked_cannot_read_by_id`, Task 5 `test_cannot_save_from_blocked`
5. **수천 명이 기록한 인기곡의 별자리**: 응답이 노드 300개를 넘지 않아야 한다(나와 친구 우선). → Task 7 `test_constellation_node_cap`

## Prerequisites (사용자 작업 — 실행 전에 한 번)

- Docker 런타임: Docker Desktop 또는 OrbStack 설치 후 실행
- `brew install supabase/tap/supabase deno`
- (Plan 2부터 필요) `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

## File Structure

```
supabase/
  config.toml                         # supabase init 생성
  seed.sql                            # 로컬 전용: tests 스키마 헬퍼
  migrations/
    20261109000100_core_schema.sql    # enums, tables, constraints, profile trigger
    20261109000200_social.sql         # are_friends, is_blocked, friend/block RPCs
    20261109000300_entries_rls.sql    # entries RLS, create_post/update_entry/delete_entry
    20261109000400_save_promote.sql   # save_entry, promote_save
    20261109000500_feeds.sql          # feed_item type, friends_feed, public_feed
    20261109000600_constellation.sql  # get_constellation
    20261109000700_archive.sql        # archive_month, my_places, entries_at_place
    20261109000800_moderation.sql     # reports RPC, auto-hide, notify trigger
    20261109000900_account.sql        # delete_my_account
  functions/notify-report/
    index.ts                          # 이메일 발송 핸들러
    handler.ts                        # 순수 함수 (테스트 대상)
    handler.test.ts
  tests/database/
    01_schema.test.sql … 09_account.test.sql
```

---

### Task 1: 프로젝트 스캐폴드와 테스트 하네스

**Files:**
- Create: `supabase/config.toml` (CLI), `supabase/seed.sql`, `supabase/tests/database/00_harness.test.sql`

**Interfaces:**
- Produces (seed.sql, `tests` 스키마, 로컬 전용):
  - `tests.create_user(p_handle text) returns uuid`: `auth.users` 행을 만들고(트리거로 profile 생성), handle과 `display_name = p_handle`을 설정한다.
  - `tests.as_user(p_id uuid) returns void`: `set_config('role','authenticated',true)`와 `set_config('request.jwt.claims', json {"sub":id,"role":"authenticated"}, true)`.
  - `tests.as_service() returns void`: `role`을 `postgres`로 되돌린다.
  - `tests.make_friends(a uuid, b uuid) returns void`: accepted friendship을 직접 넣는다.
  - `tests.song(p_id text, p_isrc text default null) returns text`: songs에 넣고 group_key를 반환한다.
  - `tests.post(p_user uuid, p_song text, p_vis entry_visibility default 'friends') returns uuid`: as_user 후 `create_post`를 호출하고 as_service로 복귀한다.

- [ ] **Step 1:** `supabase init` 실행. `supabase start` 후 `supabase status`에 DB URL이 나오는지 확인한다.
- [ ] **Step 2: 실패하는 하네스 테스트 작성** (`00_harness.test.sql`)

```sql
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);
select has_function('tests', 'create_user', array['text']);
select isnt(tests.create_user('alice'), null, 'creates user');
select * from finish();
rollback;
```
- [ ] **Step 3:** `supabase test db` → FAIL (`tests.create_user` 없음)
- [ ] **Step 4:** `seed.sql`에 헬퍼를 구현한다. `create_user`는 Task 2의 profile 트리거에 의존하므로, Task 1에서는 `auth.users` insert와 id 반환만 하고, profile 갱신은 `if exists` 가드로 감싼다.
- [ ] **Step 5:** `supabase db reset && supabase test db` → PASS
- [ ] **Step 6: Commit** `chore: scaffold supabase project and test harness`

---

### Task 2: 핵심 스키마

**Files:**
- Create: `supabase/migrations/20261109000100_core_schema.sql`, `supabase/tests/database/01_schema.test.sql`

**Interfaces:**
- Produces:
  - 타입: `entry_visibility('private','friends','public')`, `entry_kind('post','save')`, `entry_status('active','hidden','deleted')`, `friendship_status('pending','accepted')`
  - `profiles(id uuid pk → auth.users on delete cascade, handle citext unique null check (handle ~ '^[a-z0-9_.]{3,20}$'), display_name text null check (char_length 1..30), star_color text not null check (~ '^#[0-9A-F]{6}$'), created_at)`
  - `songs(id text pk, isrc text null, title text not null, artist text not null, artwork_url text null, group_key text generated always as (coalesce(isrc,'am:'||id)) stored, index on group_key)`
  - `entries(id uuid pk, user_id uuid null → profiles on delete set null, song_id text not null → songs, listened_at timestamptz null, place_name text null check ≤60, place_lat float8 null, place_lng float8 null, comment text null check ≤500, visibility entry_visibility not null, kind entry_kind not null, source_entry_id uuid null → entries on delete set null, status entry_status not null default 'active', report_count int not null default 0, posted_at timestamptz null, created_at timestamptz not null default now())`
    - checks: `(place_lat is null) = (place_lng is null)`; `kind <> 'save' or (visibility = 'private' and source_entry_id is not null)`; `(kind = 'post') = (posted_at is not null) or status = 'deleted'`
    - partial unique: `(user_id, source_entry_id) where kind='save' and status<>'deleted'`
    - indexes: `(posted_at desc, id desc) where kind='post' and status='active'`, `(source_entry_id)`, `(user_id, listened_at)`
  - `friendships(user_low uuid, user_high uuid, status friendship_status, requested_by uuid, created_at, pk(user_low,user_high), check user_low < user_high)`, 양쪽 FK on delete cascade
  - `blocks(blocker uuid, blocked uuid, pk(blocker,blocked), check blocker<>blocked)`, FK cascade
  - `reports(reporter uuid → profiles on delete set null, entry_id uuid → entries, reason text check ≤200, created_at, unique(reporter, entry_id))`
  - 트리거 `on auth.users insert` → profile 생성. `star_color`는 아래 12색 팔레트에서 무작위로 고른다: `#FFD166 #06D6A0 #EF476F #118AB2 #A78BFA #F78C6B #4CC9F0 #F15BB5 #9BE564 #FF9F1C #2EC4B6 #E0AAFF`
  - `set_profile(p_handle text, p_display_name text) returns profiles`: SECURITY DEFINER, 본인 행. handle은 `lower(trim())`, 중복이면 `handle_taken` 예외
  - `upsert_song(p_id text, p_isrc text, p_title text, p_artist text, p_artwork_url text) returns text`: group_key 반환. isrc는 기존 값이 null일 때만 채운다.
  - 모든 테이블 RLS enable. `revoke insert, update, delete on all tables in schema public from anon, authenticated`. `profiles`와 `songs`는 authenticated select 허용(profiles 차단 필터는 Task 3).

- [ ] **Step 1: 실패 테스트** `01_schema.test.sql`. assertions:
  - `throws_ok` save인데 visibility='friends' → check violation `23514`
  - `throws_ok` place_lat만 있고 lng null → `23514`
  - `throws_ok` `set_profile('민지','민지')` → `23514` (`test_handle_rejects_non_ascii`)
  - `is(tests.song('1','KRA0001'), 'KRA0001')`, `is(tests.song('2'), 'am:2')`
  - 같은 ISRC 다른 id 두 곡의 group_key가 같다
  - 새 유저의 `star_color`가 팔레트 12색 중 하나다
  - authenticated로 `insert into entries` → `42501`
- [ ] **Step 2:** `supabase test db` → FAIL
- [ ] **Step 3:** 마이그레이션 작성. `create extension if not exists citext`
- [ ] **Step 4:** `supabase db reset && supabase test db` → PASS. Task 1의 `tests.create_user`가 profile handle을 설정하도록 가드를 제거한다.
- [ ] **Step 5: Commit** `feat(db): core schema`

---

### Task 3: 친구와 차단

**Files:**
- Create: `supabase/migrations/20261109000200_social.sql`, `supabase/tests/database/02_social.test.sql`

**Interfaces:**
- Consumes: Task 2 tables
- Produces (모두 `SECURITY DEFINER`, `set search_path = public`, 호출자 = `auth.uid()`):
  - `are_friends(a uuid, b uuid) returns boolean`: accepted 상태이고 어느 방향으로도 차단이 없다. stable
  - `is_blocked_between(a uuid, b uuid) returns boolean`: stable
  - `send_friend_request(p_handle text) returns friendship_status`: 상대가 이미 나에게 pending을 보냈으면 accepted로 바꾼다. 자기 자신이면 `cannot_friend_self`, 차단 관계면 `user_not_found`(존재를 숨김)
  - `accept_friend_request(p_user uuid) returns void`: `requested_by = p_user`인 pending만 처리한다
  - `remove_friend(p_user uuid) returns void`: 거절과 취소에도 쓴다
  - `block_user(p_user uuid) returns void`: friendship 행을 삭제한다
  - `unblock_user(p_user uuid) returns void`
  - `my_friends() returns table(user_id uuid, handle citext, display_name text, star_color text)`
  - `incoming_requests() returns table(user_id uuid, handle citext, display_name text, created_at timestamptz)`
  - profiles select 정책 변경: `not is_blocked_between(auth.uid(), id)`

- [ ] **Step 1: 실패 테스트** `02_social.test.sql`:
  - alice → `send_friend_request('bob')`가 `'pending'` 반환. bob이 `accept_friend_request(alice)` 후 `are_friends(alice,bob)` true
  - 서로 동시에 요청하면 두 번째 호출이 `'accepted'` 반환
  - bob이 alice의 요청을 수락하는 게 아니라 alice가 스스로 수락하면 상태가 그대로 pending
  - `block_user`가 friendship을 지우고, alice로 select 시 bob 프로필이 0행
  - 차단 후 `send_friend_request`가 `user_not_found`로 throw
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5: Commit** `feat(db): friendships and blocks`

---

### Task 4: 기록 작성, 수정, 삭제와 RLS

**Files:**
- Create: `supabase/migrations/20261109000300_entries_rls.sql`, `supabase/tests/database/03_entries.test.sql`

**Interfaces:**
- Consumes: `are_friends`, `is_blocked_between`
- Produces:
  - **RLS select on entries**: 아래 둘 중 하나면 볼 수 있다.
    - `user_id = auth.uid() and status <> 'deleted'`
    - `status = 'active' and kind = 'post' and not is_blocked_between(auth.uid(), user_id) and (visibility = 'public' or (visibility = 'friends' and are_friends(auth.uid(), user_id)))`
  - 내부 헬퍼 `norm_text(t text) returns text`: trim 후 빈 문자열이면 null
  - `create_post(p_song_id text, p_listened_at timestamptz, p_place_name text, p_place_lat float8, p_place_lng float8, p_comment text, p_visibility entry_visibility) returns entries`: `posted_at = now()`. `p_listened_at`이 null이면 `now()`
  - `update_entry(p_entry_id uuid, p_listened_at timestamptz, p_place_name text, p_place_lat float8, p_place_lng float8, p_comment text, p_visibility entry_visibility default null) returns entries`: 본인 것만 수정할 수 있다. 저장 항목에 visibility를 주면 `save_is_private` 예외. 남의 것이나 없는 항목이면 `entry_not_found`
  - `delete_entry(p_entry_id uuid) returns void`: `status='deleted'`, `comment/place_*/listened_at = null`

- [ ] **Step 1: 실패 테스트** `03_entries.test.sql`. 유저 alice, bob(alice 친구), carol(남), dave(alice가 차단):
  - alice의 friends 글: bob 1행, carol 0행
  - alice의 public 글: carol 1행
  - alice의 private 글: bob 0행, alice 1행
  - `test_blocked_cannot_read_by_id`: dave가 alice의 public 글 id로 select 시 0행
  - `test_blank_comment_becomes_null`: `create_post(..., p_comment => '   ')`의 comment가 null
  - bob이 alice 글을 `update_entry` → `entry_not_found`
  - `delete_entry` 후 alice 본인도 0행. as_service로 보면 `comment is null and status='deleted'`
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5: Commit** `feat(db): entries rls and post rpcs`

---

### Task 5: 저장과 피드에 올리기

**Files:**
- Create: `supabase/migrations/20261109000400_save_promote.sql`, `supabase/tests/database/04_save_promote.test.sql`

**Interfaces:**
- Consumes: entries RLS (출처 확인은 **invoker 권한의 select**로 한다. 그래서 내부에서 `select ... from entries where id = p_source_entry_id`를 RLS가 적용된 상태로 확인한 뒤 definer 블록에서 insert한다. 구현 방식은 자유지만, 볼 수 없는 출처는 반드시 `entry_not_found`)
- Produces:
  - `save_entry(p_source_entry_id uuid, p_place_name text default null, p_place_lat float8 default null, p_place_lng float8 default null) returns entries`
    - 결과: `kind='save'`, `visibility='private'`, song은 출처와 같고, `listened_at = now()`
    - 내 글이면 `cannot_save_own`
    - 같은 `group_key`의 active 항목이 내 아카이브에 이미 있으면 `already_in_archive`
  - `promote_save(p_entry_id uuid, p_visibility entry_visibility, p_comment text, p_place_name text, p_place_lat float8, p_place_lng float8) returns entries`
    - 결과: `kind='post'`, `posted_at = now()`. `source_entry_id`는 유지
    - 이미 post면 `already_posted`

- [ ] **Step 1: 실패 테스트**:
  - bob이 alice의 friends 글을 저장하면 `kind='save'`, `visibility='private'`, `source_entry_id` = alice 글
  - carol(남)이 같은 글을 저장 → `entry_not_found`
  - `test_cannot_save_from_blocked`: dave가 alice의 public 글을 저장 → `entry_not_found`
  - `test_save_same_song_twice`: bob이 같은 곡(다른 entry, 같은 ISRC)을 다시 저장 → `already_in_archive`
  - bob의 저장 항목을 alice가 select → 0행 (저장 내용 비공개)
  - bob이 `promote_save(..., 'friends', '좋다', ...)` → alice가 select 1행, `source_entry_id` 유지
  - carol이 bob의 승격된 public 글을 저장 → 성공 (A→B→C 체인)
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5: Commit** `feat(db): save and promote`

---

### Task 6: 피드

**Files:**
- Create: `supabase/migrations/20261109000500_feeds.sql`, `supabase/tests/database/05_feeds.test.sql`

**Interfaces:**
- Consumes: entries RLS, `are_friends`
- Produces (`SECURITY INVOKER`, RLS가 그대로 적용됨):
  - 타입 `feed_item(entry_id uuid, author_id uuid, author_handle citext, author_name text, author_color text, song_id text, song_title text, song_artist text, artwork_url text, group_key text, listened_at timestamptz, place_name text, place_lat float8, place_lng float8, comment text, visibility entry_visibility, posted_at timestamptz, source_entry_id uuid, source_author_name text)`
    - `source_author_name`: 출처 기록이 호출자에게 보이고 그 작성자를 볼 수 있으면 `display_name`, 아니면 null. 앱은 null이면 "누군가에게서"로 표시한다.
  - `friends_feed(p_before_posted_at timestamptz default null, p_before_id uuid default null, p_limit int default 20) returns setof feed_item`
    - 조건: `kind='post'`, active, `visibility in ('friends','public')`, 작성자 = 나 또는 `are_friends`
    - 정렬: `(posted_at, id) < (p_before_posted_at, p_before_id)`, `order by posted_at desc, id desc`
  - `public_feed(...)` (같은 시그니처): `visibility='public'`, active, 차단 관계 제외
  - `p_limit`는 1..50으로 clamp한다

- [ ] **Step 1: 실패 테스트**:
  - friends_feed(alice)에 alice 본인 글과 bob 글이 포함되고, carol의 public 글은 없다
  - public_feed(alice)에 carol의 public 글이 포함되고, bob의 friends 글은 없다
  - 저장 항목은 두 피드 어디에도 없다
  - 숨김(`hidden`) 글은 없다
  - `test_feed_cursor_ties`: 같은 `posted_at`인 글 3개를 `p_limit=2`로 두 페이지 조회하면 합쳐서 정확히 3개이고 중복이 없다
  - 차단된 사람이 출처인 글의 `source_author_name`이 null이다
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5: Commit** `feat(db): friends and public feeds`

---

### Task 7: 별자리

**Files:**
- Create: `supabase/migrations/20261109000600_constellation.sql`, `supabase/tests/database/06_constellation.test.sql`

**Interfaces:**
- Consumes: entries, `are_friends`, `is_blocked_between`
- Produces: `get_constellation(p_group_key text, p_focus_entry_id uuid default null) returns jsonb`. `SECURITY DEFINER`이며 **content 컬럼(comment, place_*, listened_at)을 절대 반환하지 않는다.**

```
{ "nodes": [ { "entry_id", "kind", "is_me", "is_friend", "anonymous", "gone",
               "user_id"(anonymous면 null), "display_name"(null), "star_color"(null),
               "size", "can_open" } ],
  "edges": [ { "from": source_entry_id, "to": entry_id } ],
  "truncated": bool }
```
- **포함 규칙**은 아래 순서대로 적용한다.
  1. 후보: 같은 `group_key`의 항목 중 `hidden`/`deleted`가 아닌 것. `private` post는 출처나 자식이 있을 때만 후보가 된다. `hidden`/`deleted`는 출처나 자식이 있을 때만 `gone=true`로 후보가 된다.
  2. 시작점(seed): 나 또는 친구의 후보 항목, 그리고 `p_focus_entry_id`(그 항목이 호출자에게 RLS상 보일 때만).
  3. seed가 속한 연결 컴포넌트 전체를 source 간선을 따라 양방향으로 확장한다(recursive CTE). 출처나 자식이 없는 독립 항목은 seed 자신만 포함한다(친구가 아닌 사람의 독립 기록은 나오지 않음).
  4. 차단 관계인 사람의 노드는 자식이 있으면 `anonymous`로 남기고, 잎이면 제외한다.
- **라벨 규칙**:
  - `is_me`: 내 항목
  - `is_friend`: `are_friends`
  - 둘 다 아니거나 `gone`이면 `anonymous = true`이고 이름, 색, user_id를 null로 둔다.
- `size`: 그 노드의 모든 하위 노드 수 (포함된 노드 기준).
- `can_open`: 호출자 기준 RLS select가 가능한지 (`exists` 서브쿼리를 invoker 관점으로 계산하거나 Task 4 정책 조건을 그대로 재사용).
- **노드 상한 300**: 넘으면 나 → 친구 → 그 경로상 조상 → 나머지 순으로 남기고 `truncated=true`.

- [ ] **Step 1: 실패 테스트** `06_constellation.test.sql`. 시나리오: alice(친구: bob) 글 A → bob 저장 후 승격 B → carol(bob 친구, alice와는 남) 저장 C → dave(남) 저장 D(출처 C). alice 관점:
  - 노드 4개, 간선 A→B, B→C, C→D
  - A의 size=3, B=2, C=1, D=0
  - carol과 dave 노드는 `anonymous` true, `display_name` null
  - bob의 B 노드는 `is_friend` true, `star_color`가 bob 색
  - 반환 JSON 전체 텍스트에 A의 comment 문자열이 포함되지 않는다 (`test_constellation_no_content`)
  - bob의 독립 기록(같은 곡, 출처 없음)이 노드로 나오고 간선은 없다
  - 친구가 아닌 eve의 독립 public 기록은 나오지 않는다
  - eve의 독립 private 기록도 나오지 않는다
  - B를 `delete_entry`하면 B 노드가 `gone` true, `anonymous` true가 되고 간선은 유지된다
  - alice가 carol을 차단하면 C는 자식(D)이 있어서 anonymous로 남는다. D가 차단 대상이면 잎이라 제외된다
  - `test_constellation_node_cap`: A에서 저장 350개(각기 다른 유저) → nodes 길이 ≤ 300, `truncated` true, A 포함
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인. `explain analyze`로 350 노드 시나리오가 200ms 이내인지 확인한다
- [ ] **Step 5: Commit** `feat(db): constellation`

---

### Task 8: 아카이브

**Files:**
- Create: `supabase/migrations/20261109000700_archive.sql`, `supabase/tests/database/07_archive.test.sql`

**Interfaces:**
- Produces (`SECURITY INVOKER`, 본인 것만):
  - 타입 `archive_item(entry_id uuid, kind entry_kind, song_id text, song_title text, song_artist text, artwork_url text, listened_at timestamptz, place_name text, place_lat float8, place_lng float8, comment text, visibility entry_visibility, source_author_name text)`
  - `archive_month(p_month date, p_tz text default 'Asia/Seoul') returns setof archive_item`: 그 달(타임존 기준)의 내 active/hidden 항목. 정렬은 `listened_at desc`
  - `place_key(p_name text, p_lat float8, p_lng float8) returns text` (immutable): 좌표가 있으면 `p_name || '@' || round(lat,4) || ',' || round(lng,4)`, 없으면 `'name:' || p_name`
  - `my_places() returns table(place_key text, place_name text, place_lat float8, place_lng float8, entry_count int, latest_artwork_url text)`: 정렬은 `entry_count desc`
  - `entries_at_place(p_place_key text) returns setof archive_item`

- [ ] **Step 1: 실패 테스트**:
  - 서울 시간 11월 1일 00:30 기록이 `archive_month('2026-11-01')`에 포함되고 10월에는 없다
  - 같은 POI 이름과 좌표 2개, 같은 직접입력 이름 1개, 다른 직접입력 이름 1개 → `my_places` 3행, 첫 행 count=2
  - 저장 항목도 포함되고 `source_author_name`이 출처 작성자 이름이다
  - bob이 호출하면 alice 항목 0행
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5: Commit** `feat(db): archive queries`

---

### Task 9: 신고, 자동 숨김, 운영자 알림

**Files:**
- Create: `supabase/migrations/20261109000800_moderation.sql`, `supabase/tests/database/08_moderation.test.sql`, `supabase/functions/notify-report/{index.ts,handler.ts,handler.test.ts}`

**Interfaces:**
- Produces:
  - `report_entry(p_entry_id uuid, p_reason text) returns void`
    - 호출자에게 RLS상 보이는 남의 post만 신고할 수 있다. 아니면 `entry_not_found`. 같은 사람이 다시 신고하면 무시(no-op)
    - `report_count += 1`. 3 이상이면 `status='hidden'`
  - 트리거 `reports_notify` (AFTER INSERT)
    - `vault.decrypted_secrets`에서 `notify_report_url`, `notify_report_secret`을 읽는다
    - 둘 다 있으면 `net.http_post(url, body := {entry_id, reason, report_count}, headers := {Authorization: 'Bearer '||secret})`
    - 없으면 아무것도 하지 않는다. 알림 실패가 신고를 막으면 안 된다
  - Edge Function `notify-report`
    - `handler.ts`: `export function buildEmail(p: {entry_id: string; reason: string; report_count: number}, dashboardUrl: string): {subject: string; text: string}`
    - `index.ts`: Authorization 헤더가 `NOTIFY_REPORT_SECRET`과 다르면 401. 맞으면 Resend API(`RESEND_API_KEY`)로 `OPERATOR_EMAIL`에 보낸다

- [ ] **Step 1: 실패 테스트** (SQL):
  - 서로 다른 3명이 신고하면 `status='hidden'`이고, 친구 피드와 RLS select에서 사라진다
  - 같은 사람이 두 번 신고해도 count=1
  - Vault 비밀이 없어도 `report_entry`가 성공한다
  - 자기 글 신고 → `entry_not_found`
- [ ] **Step 2: 실패 테스트** (Deno) `handler.test.ts`:
  - `report_count` 3일 때 subject에 `"[숨김됨]"` 포함
  - text에 `entry_id`와 `dashboardUrl` 포함
- [ ] **Step 3:** `supabase test db` 와 `deno test supabase/functions/notify-report/` → FAIL 확인
- [ ] **Step 4:** 구현
- [ ] **Step 5:** 둘 다 PASS 확인
- [ ] **Step 6: Commit** `feat(db): reports, auto-hide, operator notify`

---

### Task 10: 계정 삭제

**Files:**
- Create: `supabase/migrations/20261109000900_account.sql`, `supabase/tests/database/09_account.test.sql`

**Interfaces:**
- Produces: `delete_my_account() returns void` (SECURITY DEFINER)
  1. 내 모든 entries를 tombstone 처리한다: `status='deleted'`, 내용 null
  2. `delete from auth.users where id = auth.uid()` (profile은 cascade, `entries.user_id`는 FK `set null`, friendships와 blocks는 cascade)
  - Apple 토큰 revoke는 Plan 4에서 앱과 Edge Function이 처리한다(이 RPC 호출 전에).

- [ ] **Step 1: 실패 테스트**:
  - bob이 alice 글을 저장한 상태에서 alice가 삭제하면:
    - alice의 profiles 행 0개
    - alice 글 행은 남아 있고 `user_id is null`, `comment is null`
    - bob의 저장은 그대로 있고 `source_entry_id` 유지
  - bob 관점 별자리에서 alice 노드가 `gone` true, `anonymous` true
  - bob의 `my_friends()`에서 alice가 사라진다
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5: Commit** `feat(db): account deletion with tombstones`

---

### Task 11: 타입 생성과 원격 배포 준비

**Files:**
- Create: `supabase/README.md` (실행, 테스트, 배포 방법과 Vault/Edge 비밀 목록)

- [ ] **Step 1:** `supabase db reset && supabase test db` → 전체 PASS (00~09)
- [ ] **Step 2:** `supabase db lint` → error 0
- [ ] **Step 3:** README에 다음을 적는다.
  - 원격 배포 절차: `supabase link --project-ref <ref>` → `supabase db push` → `supabase functions deploy notify-report` → `supabase secrets set RESEND_API_KEY OPERATOR_EMAIL NOTIFY_REPORT_SECRET`
  - Vault에 `notify_report_url`과 `notify_report_secret` 등록
  - **원격 배포는 사용자가 Supabase 프로젝트를 만든 뒤 직접 실행한다.**
- [ ] **Step 4: Commit** `docs(db): backend runbook`
