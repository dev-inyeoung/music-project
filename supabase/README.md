# 백엔드 런북 (Supabase)

음악 일기 앱의 Supabase 백엔드: Postgres 마이그레이션(`migrations/`), pgTAP 테스트(`tests/database/`), Edge Function(`functions/notify-report`).

## 사전 준비

- OrbStack(또는 Docker)
- `brew install supabase/tap/supabase deno`

## 로컬 실행

```sh
supabase start        # 로컬 스택 기동
supabase db reset     # 마이그레이션 + seed.sql 재적용
supabase test db      # pgTAP 전체 (00~09)
supabase db lint      # 스키마 린트 (error 0이어야 함)
deno test supabase/functions/notify-report/   # Edge Function 단위 테스트
```

## 원격 배포

**원격 배포는 사용자가 Supabase 프로젝트를 만든 뒤 직접 실행한다.** (자동화/에이전트가 실행하지 않는다.)

```sh
supabase link --project-ref <ref>
supabase db push
supabase functions deploy notify-report
supabase secrets set RESEND_API_KEY=... OPERATOR_EMAIL=... NOTIFY_REPORT_SECRET=... DASHBOARD_URL=...
# 선택: NOTIFY_FROM_EMAIL (기본값 onboarding@resend.dev)
```

`notify-report`는 `config.toml`에서 `verify_jwt = false`이며, 요청 헤더의 공유 비밀(`NOTIFY_REPORT_SECRET`)로 인증한다.

### Edge Function 비밀

| 이름 | 설명 |
|---|---|
| `RESEND_API_KEY` | Resend API 키 |
| `OPERATOR_EMAIL` | 신고 알림 수신 주소 |
| `NOTIFY_REPORT_SECRET` | DB 트리거와 공유하는 비밀 (Vault `notify_report_secret`과 동일해야 함) |
| `NOTIFY_FROM_EMAIL` | (선택) 발신 주소, 기본 `onboarding@resend.dev` |
| `DASHBOARD_URL` | 메일에 넣을 대시보드 링크 |

### Vault 등록

신고 트리거(`reports_notify`)는 Vault에서 URL과 비밀을 읽는다. 원격 SQL Editor에서 한 번 실행:

```sql
select vault.create_secret('https://<ref>.supabase.co/functions/v1/notify-report', 'notify_report_url');
select vault.create_secret('<NOTIFY_REPORT_SECRET과 같은 값>', 'notify_report_secret');
```

Vault 값이 없거나 호출이 실패해도 신고 자체는 정상 처리된다(알림만 생략).

## iOS 앱이 호출하는 RPC

모두 `authenticated` 전용이며 인증 없으면 `not_authenticated`를 던진다. 테이블 직접 쓰기는 불가(RLS), 쓰기는 RPC로만.

| RPC | 용도 |
|---|---|
| `set_profile(handle, display_name)` | 내 핸들/표시 이름 설정 |
| `upsert_song(id, isrc, title, artist, artwork_url)` | 곡 등록, group_key 반환 |
| `create_post(song_id, listened_at, place_name, lat, lng, comment, visibility)` | 글 작성 |
| `update_entry(entry_id, listened_at, place_*, comment, visibility?)` | 내 기록 수정 |
| `delete_entry(entry_id)` | 내 기록 삭제 |
| `save_entry(source_entry_id, place_*?)` | 친구 글을 내 아카이브에 저장 |
| `promote_save(entry_id, visibility, comment, place_*)` | 저장본을 내 글로 승격 |
| `send_friend_request(handle)` | 친구 요청 (결과 상태 반환) |
| `accept_friend_request(user)` / `remove_friend(user)` | 요청 수락 / 친구 삭제 |
| `block_user(user)` / `unblock_user(user)` | 차단 / 해제 |
| `my_friends()` / `incoming_requests()` | 친구 목록 / 받은 요청 |
| `friends_feed(before_posted_at?, before_id?, limit=20)` | 친구 피드 (커서 페이징) |
| `public_feed(before_posted_at?, before_id?, limit=20)` | 공개 피드 (커서 페이징) |
| `get_constellation(group_key, focus_entry_id?)` | 같은 곡 별자리 데이터 |
| `archive_month(month, tz='Asia/Seoul')` | 월별 아카이브 |
| `my_places()` / `entries_at_place(place_key)` | 장소 목록 / 장소별 기록 |
| `report_entry(entry_id, reason)` | 글 신고 (3건 누적 시 자동 숨김) |
| `delete_my_account()` | 계정 삭제 |

## 앱이 처리할 에러 코드

`raise exception`(P0001)의 메시지로 전달된다.

`not_authenticated`, `handle_invalid`, `handle_taken`, `user_not_found`, `cannot_friend_self`, `cannot_block_self`, `entry_not_found`, `save_is_private`, `cannot_save_own`, `already_in_archive`, `already_posted`
