# Plan 2: iOS 기반 (로그인, 프로필, 기록하기, 아카이브) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SwiftUI iOS 앱의 뼈대를 만든다. 사용자는 Apple로 로그인하고 프로필(핸들, 이름)을 정한 뒤, 곡, 시간, 장소, 코멘트, 공개 범위로 기록을 남기고 날짜별(달력)과 장소별(지도+목록) 아카이브에서 다시 본다.

**Architecture:**
- 로직은 로컬 Swift 패키지 `DiaryCore`에 둔다. 모델, 백엔드 API, `@Observable` 화면 모델이 여기 들어가고, macOS에서 `swift test`로 빠르게 테스트한다.
- 앱 타깃 `MusicDiary`는 SwiftUI 화면과 Apple 프레임워크 어댑터만 담는다. 어댑터는 AuthenticationServices, MusicKit, MapKit, CoreLocation이다.
- 백엔드 접근은 프로토콜 `DiaryAPI` 하나로 감싼다. 단위 테스트는 가짜(`FakeDiaryAPI`)를 쓰고, 통합 테스트는 로컬 Supabase에 붙는다.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, iOS 18+, XcodeGen, supabase-swift 2.x (SPM), MusicKit, MapKit, CoreLocation, AuthenticationServices, XCTest/Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-09-music-diary-app-design.md`
**Backend contract:** `supabase/README.md` (RPC 목록, 오류 코드), `supabase/migrations/*.sql`

**Plan 시리즈:** 1 백엔드(완료, PR #1) → **2 iOS 기반(이 문서)** → 3 피드, 저장, 별자리 → 4 친구, 차단, 신고, 계정 삭제.

## Plan 1에서 넘어온 결정 (이 대화 밖에서 실행하는 사람을 위해)

- **곡 정보는 MusicKit이 원본이다.** `songs` 테이블은 먼저 등록한 사람의 값이 남는 캐시이므로, 화면에는 MusicKit에서 받은 제목, 아티스트, 아트워크를 우선 보여주고 DB 값은 대체값으로만 쓴다.
- **`artwork_url`은 `https://<host>.mzstatic.com/...`만 저장된다.** 그 외 URL은 `nil`로 보낸다. 다른 값을 보내면 CHECK 위반(23514)이 난다.
- **모든 RPC는 로그인 필요.** 로그인 없이 부르면 `not_authenticated`가 난다. 오류는 P0001의 message 문자열로 온다: `not_authenticated, handle_invalid, handle_taken, user_not_found, cannot_friend_self, cannot_block_self, entry_not_found, save_is_private, cannot_save_own, already_in_archive, already_posted`.
- **아카이브 월 경계는 서버가 `p_tz`로 계산한다.** 앱은 `TimeZone.current.identifier`를 넘긴다.
- **회색 별, 별자리, 피드, 저장은 Plan 3 범위다.** 이 계획에서는 다루지 않는다.

## Global Constraints

- 최소 iOS 18.0, Swift 6 언어 모드(strict concurrency).
- Bundle ID: `io.github.devinyeoung.musicdiary` **[Claude 결정]**. 앱 표시 이름: `음악일기` **[Claude 결정, 바꾸기 쉬움]**.
- 로그인은 **Sign in with Apple 하나만** 둔다(스펙 3).
  - 개발용 이메일 로그인은 `#if DEBUG`에서만 컴파일된다.
  - 그리고 Supabase URL 호스트가 `127.0.0.1` 또는 `localhost`일 때만 화면에 나타난다.
- 하단 탭은 `피드` · `＋기록` · `아카이브`(스펙 5.1). 피드 탭은 이 계획에서 "곧 열려요" 자리 표시 화면이다.
- 기록 입력(스펙 5.3):
  - 곡: 필수.
  - 언제: 기본값 지금, 수정 가능.
  - 어디서: 근처 장소 고르기, 직접 입력, 또는 생략. 근처 장소면 이름과 좌표를 함께 저장하고, 직접 입력이면 이름만 저장한다.
  - 코멘트: 자유 텍스트, 감정 선택 UI 없음.
  - 공개 범위: `나만 보기` / `친구에게` / `전체에게`, 기본값 `친구에게`.
- 핸들 규칙은 서버와 같다: `^[a-z0-9_.]{3,20}$`(소문자로 바꾼 뒤 검사). 표시 이름은 1~30자.
- 코멘트는 500자 이하, 장소 이름은 60자 이하(서버 CHECK와 동일). 앱이 미리 막는다.
- 아카이브는 `[날짜 | 장소]` 두 가지이고 감정 정렬은 없다(스펙 5.6).
  - 날짜: 기록이 있는 날 칸에 앨범 아트를 보여준다. 하루에 여러 곡이면 가장 늦게 들은 곡 하나와 개수를 보여준다.
  - 장소: 지도에는 좌표가 있는 장소만 곡 수와 함께 표시하고, 목록에는 모든 장소를 보여준다.
- 화면 톤은 어두운 배경 기조다(스펙 7). 내 `star_color`를 프로필과 아카이브의 강조색으로 쓴다.
- 비밀값(Supabase anon key, Team ID)은 커밋하지 않는다. `ios/Config/Local.xcconfig`에 두고 gitignore한다.
- 사용자에게 보이는 문구는 한국어다.

## Review Focus

1. **네트워크나 서버 오류로 기록 저장이 실패한 경우**: 입력한 곡, 시간, 장소, 코멘트가 그대로 남고 다시 시도할 수 있어야 한다. → Task 8 `test_submitFailureKeepsDraft`
2. **위치 권한을 거부한 경우**: 근처 장소 목록은 비어도 직접 입력은 되어야 하고, 앱이 막히면 안 된다. → Task 7 `test_locationDeniedStillAllowsManual`
3. **Apple Music 권한 거부 또는 검색 결과 없음**: 검색 화면에 이유가 한국어로 보이고 기록 화면이 깨지면 안 된다. → Task 6 `test_searchUnauthorizedShowsMessage`
4. **이미 쓰는 핸들, 형식이 틀린 핸들**: 입력란 아래에 구체적인 한국어 메시지가 나와야 한다. 서버 코드 `handle_taken`, `handle_invalid`를 매핑한다. → Task 5 `test_handleTakenMessage`
5. **자정 근처 기록(현지 00:30)**: 달력의 올바른 날짜 칸에 들어가야 한다. 칸 나누기는 기기 현지 달력 기준이다. → Task 9 `test_bucketsByLocalDay`

## Prerequisites (사용자 작업 — 실행 전에 한 번)

- PR #1(백엔드) 병합, 또는 이 계획을 `feat/plan-1-supabase-backend` 위 새 브랜치에서 실행
- `brew install xcodegen`
- Xcode 선택: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. 이 작업이 어려우면 모든 명령 앞에 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 붙여도 된다.
- Apple Developer 포털에서 App ID `io.github.devinyeoung.musicdiary`를 만들고 **Sign in with Apple**과 **MusicKit** 서비스를 켠다. Team ID를 `ios/Config/Local.xcconfig`의 `DEVELOPMENT_TEAM`에 넣는다(Task 1이 템플릿을 만든다).
- 로컬 Supabase 실행: `supabase start`. `supabase status`에 나오는 API URL과 anon key를 `Local.xcconfig`에 넣는다.

## File Structure

```
ios/
  project.yml                      # XcodeGen 정의 (앱 타깃, UI 테스트 없음)
  Config/
    Base.xcconfig                  # 공통 빌드 설정, Local.xcconfig를 #include?
    Local.xcconfig.example         # 커밋됨: SUPABASE_URL, SUPABASE_ANON_KEY, DEVELOPMENT_TEAM 자리
    Local.xcconfig                 # gitignore
  MusicDiary/                      # 앱 타깃 (SwiftUI + 어댑터)
    App/MusicDiaryApp.swift, RootView.swift, MainTabView.swift, Theme.swift, AppConfig.swift
    Auth/AppleSignIn.swift, SignInView.swift, OnboardingView.swift
    Compose/ComposeView.swift, SongSearchView.swift, PlacePickerView.swift
    Archive/ArchiveView.swift, CalendarMonthView.swift, DayEntriesView.swift,
            EntryDetailView.swift, PlacesView.swift
    Adapters/MusicKitSongSearch.swift, MusicKitSongMetadata.swift,
             MapKitPlaceSearch.swift, LocationProvider.swift
    MusicDiary.entitlements, Info.plist (XcodeGen 생성 설정)
  DiaryCore/                       # 로컬 Swift 패키지 (macOS+iOS)
    Package.swift
    Sources/DiaryCore/
      Models/ (Visibility.swift, Profile.swift, ArchiveItem.swift, PlaceSummary.swift,
               SongCandidate.swift, PlaceChoice.swift, Draft.swift)
      Backend/ (DiaryAPI.swift, BackendError.swift, SupabaseDiaryAPI.swift, AuthService.swift)
      Features/ (SessionModel.swift, OnboardingModel.swift, SongSearchModel.swift,
                 PlacePickerModel.swift, ComposeModel.swift, ArchiveCalendarModel.swift,
                 ArchivePlacesModel.swift, EntryEditModel.swift, ErrorText.swift)
      Testing/FakeDiaryAPI.swift   # 테스트와 SwiftUI 미리보기에서 공용
    Tests/DiaryCoreTests/ ...      # 단위 테스트
    Tests/DiaryCoreIntegrationTests/  # 로컬 Supabase 통합 테스트 (DIARY_INTEGRATION=1일 때만 실행)
scripts/ios-check.sh               # swift test + xcodegen + xcodebuild build를 한 번에
```

---

### Task 1: 프로젝트 골격과 빌드 스크립트

**Files:**
- Create: `ios/project.yml`, `ios/Config/Base.xcconfig`, `ios/Config/Local.xcconfig.example`, `ios/DiaryCore/Package.swift`, `ios/DiaryCore/Sources/DiaryCore/DiaryCore.swift`, `ios/DiaryCore/Tests/DiaryCoreTests/SmokeTests.swift`, `ios/MusicDiary/App/MusicDiaryApp.swift`, `ios/MusicDiary/App/AppConfig.swift`, `scripts/ios-check.sh`
- Modify: `.gitignore` (`ios/Config/Local.xcconfig`, `ios/*.xcodeproj`, `.build/`, `DerivedData/`)

**Interfaces:**
- Produces:
  - `DiaryCore` 패키지: platforms `.iOS(.v18)`, `.macOS(.v15)`. 의존성은 `supabase-swift` `.upToNextMajor(from: "2.0.0")`(product `Supabase`).
  - `AppConfig`(앱 타깃): `static let supabaseURL: URL`, `static let supabaseAnonKey: String`. Info.plist 키 `SUPABASE_URL`, `SUPABASE_ANON_KEY`에서 읽는다. xcconfig의 `$(SUPABASE_URL)`이 Info.plist로 들어가는데, URL의 `//`가 주석으로 잘리지 않도록 `SUPABASE_HOST`와 `SUPABASE_SCHEME`으로 나눠 넣는다.
  - `scripts/ios-check.sh`: `swift test --package-path ios/DiaryCore` → `xcodegen --spec ios/project.yml` → `xcodebuild -project ios/MusicDiary.xcodeproj -scheme MusicDiary -destination 'platform=iOS Simulator,name=iPhone 17' build`. 실패하면 0이 아닌 코드로 끝난다. `DEVELOPER_DIR`이 비어 있으면 `/Applications/Xcode.app/Contents/Developer`로 채운다.
  - 엔타이틀먼트: `com.apple.developer.applesignin = [Default]`. MusicKit은 엔타이틀먼트 없이 App ID 서비스로 켜진다.
  - Info.plist 문자열:
    - `NSAppleMusicUsageDescription = "기록할 노래를 찾기 위해 Apple Music을 사용해요."`
    - `NSLocationWhenInUseUsageDescription = "지금 있는 곳 근처 장소를 추천하기 위해 위치를 사용해요."`

- [ ] **Step 1:** `SmokeTests.swift`를 쓴다. `DiaryCore.version == "0.1.0"`을 단언한다.
- [ ] **Step 2:** `swift test --package-path ios/DiaryCore` → FAIL (`DiaryCore` 없음)
- [ ] **Step 3:** 패키지, `project.yml`, 설정 파일, 빈 `MusicDiaryApp`(Text("음악일기")), `ios-check.sh`를 만든다.
- [ ] **Step 4:** `bash scripts/ios-check.sh` → swift test PASS, `** BUILD SUCCEEDED **`
- [ ] **Step 5: Commit** `chore(ios): scaffold app, DiaryCore package, check script`

---

### Task 2: 모델, 디코딩, 오류 매핑

**Files:**
- Create: `ios/DiaryCore/Sources/DiaryCore/Models/*.swift`, `Backend/BackendError.swift`, `Features/ErrorText.swift`, `Tests/DiaryCoreTests/ModelDecodingTests.swift`, `Tests/DiaryCoreTests/BackendErrorTests.swift`, `Tests/DiaryCoreTests/Fixtures/*.json`

**Interfaces:**
- Produces (모두 `Sendable`, `Equatable`, `Codable`, JSON 키는 snake_case):
  - `enum Visibility: String { case `private`, friends, `public` }`. 한국어 라벨은 `label`: `"나만 보기"`, `"친구에게"`, `"전체에게"`.
  - `enum EntryKind: String { case post, save }`
  - `enum EntryStatus: String { case active, hidden, deleted }`
  - `struct Profile { id: UUID; handle: String?; displayName: String?; starColor: String }`. `needsOnboarding`는 handle이나 displayName이 nil이면 true다.
  - `struct ArchiveItem`: 서버 `archive_item` 16개 필드를 모두 담는다. 필드는 entryId, kind, songId, songTitle, songArtist, artworkURL(`URL?`), listenedAt(`Date?`), placeName, placeLat, placeLng, comment, visibility, sourceAuthorName, sourceEntryId, groupKey, status다.
  - `struct PlaceSummary { placeKey, placeName, placeLat: Double?, placeLng: Double?, entryCount: Int, latestArtworkURL: URL? }`
  - `struct SongCandidate { id: String; isrc: String?; title: String; artist: String; artworkURL: URL? }`
    - `var storableArtworkURL: URL?`: scheme이 https이고 host가 `.mzstatic.com`으로 끝날 때만 값을 돌려주고, 아니면 nil.
  - `enum PlaceChoice { case none; case named(String); case poi(name: String, latitude: Double, longitude: Double) }`
  - `enum BackendError: Error, Equatable { case notAuthenticated, handleInvalid, handleTaken, entryNotFound, saveIsPrivate, cannotSaveOwn, alreadyInArchive, alreadyPosted, userNotFound, constraint(String), network, unknown(String) }`
    - `static func from(message: String, code: String?) -> BackendError`: P0001 메시지 문자열을 매핑한다. `code == "23514"`이면 `.constraint(message)`다.
  - `enum ErrorText { static func message(for: BackendError) -> String }`. 한국어 문구:
    - `handleTaken`: `"이미 사용 중인 아이디예요."`
    - `handleInvalid`: `"아이디는 영문 소문자, 숫자, _ . 로 3~20자예요."`
    - `notAuthenticated`: `"다시 로그인해 주세요."`
    - `network`: `"인터넷 연결을 확인해 주세요."`
    - `entryNotFound`: `"기록을 찾을 수 없어요."`
    - 나머지: `"문제가 생겼어요. 잠시 후 다시 시도해 주세요."`
  - 공용 `JSONDecoder.diary`: ISO8601 날짜와 소수 초를 모두 받는다. Postgres `timestamptz`는 `2026-11-01T00:30:00+09:00`과 `...00.123456+00:00` 형식 둘 다 온다.

- [ ] **Step 1: 실패 테스트**
  - `test_decodesArchiveItemFixture`: `archive_item.json`(서버 실제 형식, 마이크로초 포함)을 디코딩한다. 단언은 다음과 같다.
    - `listenedAt` == 2026-10-31T15:30:00Z
    - `visibility == .friends`
    - 저장 항목 픽스처의 `sourceAuthorName == "민지"`
  - `test_storableArtworkURL`: 아래 세 경우를 단언한다.
    - `https://is1-ssl.mzstatic.com/x.jpg` → 같은 URL
    - `http://is1-ssl.mzstatic.com/x.jpg` → nil
    - `https://evil.com/x.jpg` → nil
  - `test_backendErrorMapping`:
    - `"handle_taken"` → `.handleTaken`
    - code `"23514"` → `.constraint`
    - `"zzz"` → `.unknown("zzz")`
  - `test_profileNeedsOnboarding`: handle nil → true. 둘 다 있음 → false.
- [ ] **Step 2:** `swift test --package-path ios/DiaryCore` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS
- [ ] **Step 5: Commit** `feat(ios): core models, decoding, error mapping`

---

### Task 3: DiaryAPI와 Supabase 구현(통합 테스트 포함)

**Files:**
- Create: `Backend/DiaryAPI.swift`, `Backend/SupabaseDiaryAPI.swift`, `Testing/FakeDiaryAPI.swift`, `Tests/DiaryCoreIntegrationTests/SupabaseDiaryAPITests.swift`
- Modify: `ios/DiaryCore/Package.swift`(integration test target)

**Interfaces:**
- Consumes: Task 2 모델, `BackendError.from`
- Produces:

```swift
public protocol DiaryAPI: Sendable {
  func myProfile() async throws -> Profile
  func setProfile(handle: String, displayName: String) async throws -> Profile
  func upsertSong(_ song: SongCandidate) async throws -> String          // group_key
  func createPost(songId: String, listenedAt: Date, place: PlaceChoice,
                  comment: String?, visibility: Visibility) async throws -> UUID
  func updateEntry(id: UUID, listenedAt: Date?, place: PlaceChoice,
                   comment: String?, visibility: Visibility?) async throws
  func deleteEntry(id: UUID) async throws
  func archiveMonth(_ month: Date, timeZone: TimeZone) async throws -> [ArchiveItem]
  func myPlaces() async throws -> [PlaceSummary]
  func entriesAtPlace(_ placeKey: String) async throws -> [ArchiveItem]
}
```
- `SupabaseDiaryAPI(client: SupabaseClient)`:
  - 각 메서드는 README의 RPC를 정확한 인자 이름(`p_...`)으로 호출한다.
  - `myProfile`은 `profiles` 테이블에서 `id = auth.uid`인 한 행을 select한다.
  - `PlaceChoice`는 이렇게 변환한다.
    - `.none` → 이름, lat, lng 모두 null
    - `.named` → 이름만
    - `.poi` → 이름, lat, lng 모두
  - `archiveMonth`의 `p_month`는 해당 달 1일의 `yyyy-MM-dd`(timeZone 기준)다.
  - `PostgrestError`는 `BackendError.from`으로 바꾸고, `URLError`는 `.network`로 바꾼다.
- `FakeDiaryAPI`: 메모리에 기록을 저장하는 `actor`다. 다음 기능을 둔다.
  - 다음 호출에 넣을 오류를 지정하는 `failNext: BackendError?`
  - 호출을 기록하는 `calls: [String]`

- [ ] **Step 1: 통합 테스트 작성** (`DIARY_INTEGRATION != "1"`이면 `XCTSkip`)
  - 준비: 로컬 Supabase에 이메일과 비밀번호로 가입하고 로그인한다. URL과 anon key는 env `SUPABASE_URL`, `SUPABASE_ANON_KEY`에서 읽는다.
  - `test_profileRoundTrip`: `setProfile("tester_<rand>", "테스터")` 후 `myProfile().handle`이 일치한다.
  - `test_postAppearsInArchiveMonth`:
    - `upsertSong(id: "it-<rand>", artworkURL: https://is1-ssl.mzstatic.com/a.jpg)` 후 `createPost(...listenedAt: 2026-11-01T00:30+09:00, place: .poi("카페", 37.5, 127.0), comment: "  좋다 ", visibility: .private)`를 호출한다.
    - `archiveMonth(2026-11-01, Asia/Seoul)`에 그 기록이 있고 `comment == "좋다"`다.
  - `test_placesGrouping`: `.poi` 2개(같은 이름과 좌표)와 `.named("집")` 1개를 만든다. `myPlaces()`에서 `entryCount` 2인 장소가 맨 앞이다.
  - `test_updateAndDelete`: `updateEntry(comment: "수정")` 반영을 확인한다. `deleteEntry` 후 아카이브에서 사라진다.
  - `test_handleTakenMaps`: 두 번째 사용자가 같은 핸들로 `setProfile`하면 `BackendError.handleTaken`이 난다.
- [ ] **Step 2:** `DIARY_INTEGRATION=1 SUPABASE_URL=... SUPABASE_ANON_KEY=... swift test --package-path ios/DiaryCore --filter DiaryCoreIntegrationTests` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** 통합 테스트 PASS. `swift test`(통합 테스트 없이)도 PASS인지 확인한다(통합 테스트는 skip).
- [ ] **Step 5:** `scripts/ios-check.sh`가 env가 있으면 통합 테스트도 돌리도록 고친다.
- [ ] **Step 6: Commit** `feat(ios): DiaryAPI with Supabase implementation and integration tests`

---

### Task 4: 로그인과 세션

**Files:**
- Create: `Backend/AuthService.swift`, `Features/SessionModel.swift`, `ios/MusicDiary/Auth/AppleSignIn.swift`, `ios/MusicDiary/Auth/SignInView.swift`, `ios/MusicDiary/App/RootView.swift`, `Tests/DiaryCoreTests/SessionModelTests.swift`
- Modify: `supabase/config.toml`: `[auth.external.apple] enabled = true`, `client_id = "io.github.devinyeoung.musicdiary"`. secret 줄은 그대로 두되, 네이티브 id_token 흐름에는 secret이 필요 없다는 주석을 단다.

**Interfaces:**
- Produces:

```swift
public protocol AuthService: Sendable {
  func currentUserId() async -> UUID?
  func signInWithApple(idToken: String, nonce: String) async throws
  func signInForDevelopment(email: String, password: String) async throws   // 가입 후 로그인
  func signOut() async throws
}
@MainActor @Observable public final class SessionModel {
  public enum State: Equatable { case loading, signedOut, needsProfile(Profile), ready(Profile) }
  public private(set) var state: State
  public private(set) var errorMessage: String?
  public init(auth: AuthService, api: DiaryAPI)
  public func start() async            // 저장된 세션 확인 → 프로필 조회
  public func completeAppleSignIn(idToken: String, nonce: String) async
  public func signInForDevelopment() async   // email "dev@local.test", password "devpass123"
  public func profileUpdated(_ p: Profile)
  public func signOut() async
}
```
- `SupabaseAuthService(client:)`: `auth.signInWithIdToken(credentials: .init(provider: .apple, idToken:, nonce:))`
- `AppleSignIn`(앱 타깃): `SignInWithAppleButton`을 쓴다. raw nonce는 32바이트 랜덤이다. `request.nonce`에는 그 SHA256 hex를 넣고, Supabase에는 raw nonce를 넘긴다.
- `SignInView`: 어두운 배경, 앱 이름, Apple 버튼. 개발 로그인 버튼은 `#if DEBUG`이고 `AppConfig.supabaseURL.host`가 `127.0.0.1` 또는 `localhost`일 때만 보이며, 문구는 `"개발용 로그인"`이다.
- `RootView`: `SessionModel.state`에 따라 화면을 고른다.
  - `loading`: ProgressView
  - `signedOut`: SignInView
  - `needsProfile`: OnboardingView(Task 5)
  - `ready`: MainTabView(Task 11). Task 11 전까지는 임시 Text.

- [ ] **Step 1: 실패 테스트** (`FakeAuthService`와 `FakeDiaryAPI` 사용)
  - `test_startWithoutSessionIsSignedOut`
  - `test_appleSignInWithIncompleteProfileNeedsProfile`: 프로필 handle이 nil이면 `.needsProfile`
  - `test_appleSignInWithCompleteProfileIsReady`
  - `test_signInFailureShowsMessage`: auth가 `.network`를 던지면 `errorMessage == "인터넷 연결을 확인해 주세요."`이고 state는 `.signedOut`
  - `test_signOutReturnsToSignedOut`
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` PASS, `scripts/ios-check.sh` BUILD SUCCEEDED
- [ ] **Step 5: 수동 확인:** 시뮬레이터에서 개발용 로그인을 누르면 온보딩 자리 화면으로 넘어간다. 스크린샷을 리포트에 남긴다. Apple 로그인은 Team과 App ID 설정이 끝난 경우에만 확인하고, 못 했으면 그렇다고 적는다.
- [ ] **Step 6: Commit** `feat(ios): sign in with Apple, dev login, session model`

---

### Task 5: 온보딩(핸들, 이름)

**Files:**
- Create: `Features/OnboardingModel.swift`, `ios/MusicDiary/Auth/OnboardingView.swift`, `Tests/DiaryCoreTests/OnboardingModelTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor @Observable public final class OnboardingModel {
  public var handle: String          // 입력 시 소문자로 정규화
  public var displayName: String
  public private(set) var handleError: String?
  public private(set) var isSubmitting: Bool
  public var canSubmit: Bool         // 형식 OK && 이름 1...30자(trim) && !isSubmitting
  public init(api: DiaryAPI, onDone: @escaping @MainActor (Profile) -> Void)
  public func submit() async
}
```
- 로컬 검사는 서버와 같은 정규식 `^[a-z0-9_.]{3,20}$`다. 형식이 틀리면 `ErrorText.message(for: .handleInvalid)`를 보여준다.
- 화면: 아이디 필드(`@` 접두 표시), 이름 필드, "시작하기" 버튼, 오류는 아이디 필드 아래 빨간 글씨.

- [ ] **Step 1: 실패 테스트**
  - `test_handleIsLowercased`: `"MinJi_01"`을 넣으면 `"minji_01"`
  - `test_invalidHandleBlocksSubmit`: `"민지민지"`와 `"ab"` → `canSubmit == false`, `handleError`가 형식 문구
  - `test_handleTakenMessage`: fake가 `.handleTaken`을 던지면 `handleError == "이미 사용 중인 아이디예요."`, `onDone` 호출 없음
  - `test_successCallsOnDone`
  - `test_blankDisplayNameBlocksSubmit`: `"   "` → false
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현하고 `RootView`에 연결한다(`onDone` → `SessionModel.profileUpdated`).
- [ ] **Step 4:** PASS, BUILD SUCCEEDED
- [ ] **Step 5: Commit** `feat(ios): onboarding for handle and display name`

---

### Task 6: 곡 검색(MusicKit)과 곡 정보 표시

**Files:**
- Create: `Features/SongSearchModel.swift`, `ios/MusicDiary/Adapters/MusicKitSongSearch.swift`, `ios/MusicDiary/Adapters/MusicKitSongMetadata.swift`, `ios/MusicDiary/Compose/SongSearchView.swift`, `Tests/DiaryCoreTests/SongSearchModelTests.swift`

**Interfaces:**
- Produces (DiaryCore):

```swift
public enum SongSearchFailure: Error, Equatable { case unauthorized, network, other }
public protocol SongSearching: Sendable {
  func search(_ term: String) async throws -> [SongCandidate]   // 최대 25개
}
public protocol SongMetadataProviding: Sendable {
  func metadata(for songIds: [String]) async -> [String: SongCandidate]   // 실패 시 빈 딕셔너리
}
@MainActor @Observable public final class SongSearchModel {
  public var term: String
  public private(set) var results: [SongCandidate]
  public private(set) var message: String?     // 빈 결과, 오류 안내
  public init(searcher: SongSearching, debounce: Duration = .milliseconds(300))
  public func termChanged() async      // debounce 후 검색. 공백 term이면 결과를 비운다
}
```
- 문구:
  - 권한 없음: `"Apple Music 접근을 허용해야 노래를 찾을 수 있어요. 설정에서 허용해 주세요."`
  - 결과 없음: `"검색 결과가 없어요."`
  - 네트워크: `ErrorText`의 network 문구
- `MusicKitSongSearch`(앱): `MusicAuthorization.request()`가 authorized가 아니면 `.unauthorized`를 던진다. 검색은 `MusicCatalogSearchRequest(term:types:[Song.self])`이고 limit은 25다. 아트워크는 `song.artwork?.url(width: 300, height: 300)`이고, 결과는 `SongCandidate.storableArtworkURL` 규칙으로 저장용 값을 거른다(표시용은 원본 사용).
- `MusicKitSongMetadata`(앱): `MusicCatalogResourceRequest<Song>(matching: \.id, memberOf:)`로 한 번에 조회한다. 아카이브 화면에서 DB 캐시보다 우선해서 쓴다.

- [ ] **Step 1: 실패 테스트** (fake searcher)
  - `test_searchUnauthorizedShowsMessage`
  - `test_emptyResultsShowsMessage`
  - `test_blankTermClearsResults`
  - `test_debounceSearchesOnceForRapidTyping`: 300ms 안에 term을 세 번 바꾸면 검색 호출은 1회. 테스트에서는 debounce를 `.milliseconds(10)`으로 주입한다.
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현. 검색 화면은 목록 행(아트워크 44pt, 제목, 아티스트)을 보여주고, 행을 탭하면 `onPick(SongCandidate)`.
- [ ] **Step 4:** PASS, BUILD SUCCEEDED
- [ ] **Step 5: 수동 확인:** 시뮬레이터에서 "아이유"로 검색한다. App ID에 MusicKit이 아직 꺼져 있으면 검색은 실패하고 권한 문구가 나와야 한다. 결과를 리포트에 적는다.
- [ ] **Step 6: Commit** `feat(ios): song search with MusicKit`

---

### Task 7: 장소 고르기(근처 장소, 직접 입력)

**Files:**
- Create: `Features/PlacePickerModel.swift`, `ios/MusicDiary/Adapters/MapKitPlaceSearch.swift`, `ios/MusicDiary/Adapters/LocationProvider.swift`, `ios/MusicDiary/Compose/PlacePickerView.swift`, `Tests/DiaryCoreTests/PlacePickerModelTests.swift`

**Interfaces:**
- Produces (DiaryCore):

```swift
public struct NearbyPlace: Sendable, Equatable, Identifiable { id: String; name: String; latitude: Double; longitude: Double }
public enum LocationAccess: Sendable { case granted, denied, notDetermined }
public protocol NearbyPlaceSearching: Sendable {
  func requestAccess() async -> LocationAccess
  func nearby() async throws -> [NearbyPlace]    // 반경 300m, 최대 20개, 거리순
}
@MainActor @Observable public final class PlacePickerModel {
  public private(set) var nearby: [NearbyPlace]
  public private(set) var notice: String?
  public var manualName: String
  public init(searcher: NearbyPlaceSearching)
  public func load() async
  public func choose(_ p: NearbyPlace) -> PlaceChoice        // .poi
  public func chooseManual() -> PlaceChoice                   // trim. 빈 문자열이면 .none, 60자 초과는 60자로 자름
}
```
- 권한이 거부되면 `notice = "위치 권한이 없어 근처 장소를 보여줄 수 없어요. 직접 입력할 수 있어요."`
- `MapKitPlaceSearch`: `MKLocalPointsOfInterestRequest(center:radius: 300)`와 `CLLocationManager` 1회 위치 요청(`LocationProvider`, async 래퍼).

- [ ] **Step 1: 실패 테스트**
  - `test_locationDeniedStillAllowsManual`: denied면 `nearby` 비어 있음, `notice`가 권한 문구, `manualName = " 출근길 지하철 "` → `.named("출근길 지하철")`
  - `test_manualBlankIsNone`
  - `test_manualTruncatesTo60`
  - `test_choosePoiCarriesCoordinates`
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현. 화면은 근처 목록, 직접 입력 필드, "장소 없이" 버튼.
- [ ] **Step 4:** PASS, BUILD SUCCEEDED
- [ ] **Step 5: Commit** `feat(ios): place picker with nearby POIs and manual entry`

---

### Task 8: 기록하기 화면

**Files:**
- Create: `Models/Draft.swift`, `Features/ComposeModel.swift`, `ios/MusicDiary/Compose/ComposeView.swift`, `Tests/DiaryCoreTests/ComposeModelTests.swift`

**Interfaces:**
- Consumes: `DiaryAPI.upsertSong`, `createPost`, `SongCandidate`, `PlaceChoice`, `Visibility`
- Produces:

```swift
public struct Draft: Sendable, Equatable {
  public var song: SongCandidate?
  public var listenedAt: Date
  public var place: PlaceChoice = .none
  public var comment: String = ""
  public var visibility: Visibility = .friends
}
@MainActor @Observable public final class ComposeModel {
  public var draft: Draft
  public private(set) var isSubmitting: Bool
  public private(set) var errorMessage: String?
  public var canSubmit: Bool        // song != nil && comment.count <= 500 && !isSubmitting
  public init(api: DiaryAPI, now: @escaping @Sendable () -> Date = Date.init,
              onPosted: @escaping @MainActor (UUID) -> Void)
  public func submit() async        // upsertSong → createPost(comment: trim, 빈 문자열이면 nil). 성공하면 draft 초기화
}
```
- 화면 구성:
  - 곡 선택 칸: 탭하면 SongSearchView 시트
  - 날짜/시간 `DatePicker`: 미래는 막는다(`...now`)
  - 장소 칸: 탭하면 PlacePickerView 시트
  - 코멘트 `TextEditor`: 남은 글자 수 표시
  - 공개 범위 세그먼트: `나만 보기 | 친구에게 | 전체에게`
  - "기록하기" 버튼
- 성공하면 아카이브 탭으로 이동하는 콜백을 부른다(Task 11에서 연결).

- [ ] **Step 1: 실패 테스트**
  - `test_defaultVisibilityIsFriends`, `test_defaultListenedAtIsNow`(주입된 now)
  - `test_cannotSubmitWithoutSong`
  - `test_commentOver500BlocksSubmit`
  - `test_submitCallsUpsertThenCreate`: fake `calls == ["upsertSong", "createPost"]`, 공백 코멘트는 nil로 전달
  - `test_submitFailureKeepsDraft`: `createPost`가 `.network`를 던지면 draft는 그대로, `errorMessage`는 네트워크 문구, `onPosted` 미호출
  - `test_successResetsDraft`: song nil, visibility `.friends`, comment ""
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS, BUILD SUCCEEDED
- [ ] **Step 5: Commit** `feat(ios): compose a diary entry`

---

### Task 9: 아카이브 날짜 탭(달력, 하루 목록, 상세 편집과 삭제)

**Files:**
- Create: `Features/ArchiveCalendarModel.swift`, `Features/EntryEditModel.swift`, `ios/MusicDiary/Archive/ArchiveView.swift`, `CalendarMonthView.swift`, `DayEntriesView.swift`, `EntryDetailView.swift`, `Tests/DiaryCoreTests/ArchiveCalendarModelTests.swift`, `Tests/DiaryCoreTests/EntryEditModelTests.swift`

**Interfaces:**
- Produces:

```swift
public struct DayCell: Sendable, Equatable { public let day: DateComponents; public let representative: ArchiveItem; public let count: Int }
@MainActor @Observable public final class ArchiveCalendarModel {
  public private(set) var month: Date                 // 그 달 1일 00:00 (calendar 기준)
  public private(set) var cells: [Int: DayCell]       // key = 일(1...31)
  public private(set) var errorMessage: String?
  public init(api: DiaryAPI, metadata: SongMetadataProviding, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init)
  public func load() async
  public func showPreviousMonth() async
  public func showNextMonth() async                    // 이번 달 이후로는 이동하지 않음
  public func items(onDay day: Int) -> [ArchiveItem]   // listenedAt 내림차순
  public func refreshAfterChange() async
}
@MainActor @Observable public final class EntryEditModel {
  public init(item: ArchiveItem, api: DiaryAPI, onChanged: @escaping @MainActor () -> Void)
  public var listenedAt: Date; public var place: PlaceChoice; public var comment: String
  public var visibility: Visibility                 // 저장 항목이면 편집 UI에서 숨김
  public var canEditVisibility: Bool                // kind == .post
  public func save() async
  public func delete() async
}
```
- 칸 나누기: `calendar.component(.day, from: listenedAt)`. 칸의 대표는 그날 가장 늦게 들은 기록이다.
- 아트워크와 제목: `metadata.metadata(for:)` 결과가 있으면 그 값을 쓰고, 없으면 `ArchiveItem`의 DB 값을 쓴다.
- 저장 항목은 상세 화면에 `"🔗 \(sourceAuthorName ?? "누군가")에게서 온 노래"`를 보여준다. 숨김(`hidden`) 항목에는 `"신고가 누적되어 다른 사람에게 보이지 않아요."` 배지를 단다.
- `update_entry`의 `listenedAt`이 nil이면 서버가 시간을 지우므로(Plan 1 R12), 편집 화면은 항상 현재 값을 그대로 보낸다.
- 삭제는 확인 다이얼로그 `"이 기록을 삭제할까요? 되돌릴 수 없어요."`를 거친다.

- [ ] **Step 1: 실패 테스트** (`Calendar(identifier: .gregorian)`, timeZone `Asia/Seoul` 주입)
  - `test_bucketsByLocalDay`: listenedAt 2026-10-31T15:30Z(서울 11/1 00:30) → `cells[1]` 존재, `cells[31]` 없음
  - `test_representativeIsLatestAndCountsAll`: 같은 날 3개 → count 3, representative는 가장 늦은 시각
  - `test_metadataOverridesDbTitle`
  - `test_cannotGoPastCurrentMonth`
  - `test_loadErrorShowsMessage`
  - `EntryEditModelTests`:
    - `test_saveSendsCurrentListenedAt`
    - `test_saveItemCannotChangeVisibility`: `canEditVisibility == false`, 보내는 visibility는 nil
    - `test_deleteCallsApiAndOnChanged`
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
  - 달력은 7열 그리드다. 칸은 아트워크를 둥근 사각형으로 채우고, 2개 이상이면 오른쪽 위에 개수 배지를 단다. 기록이 없는 날은 어두운 칸이다.
  - 날짜를 탭하면 아래에 그날 목록이 펼쳐지고, 행을 탭하면 상세로 간다.
- [ ] **Step 4:** PASS, BUILD SUCCEEDED
- [ ] **Step 5: Commit** `feat(ios): archive calendar with day list and entry editing`

---

### Task 10: 아카이브 장소 탭(지도와 목록)

**Files:**
- Create: `Features/ArchivePlacesModel.swift`, `ios/MusicDiary/Archive/PlacesView.swift`, `Tests/DiaryCoreTests/ArchivePlacesModelTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor @Observable public final class ArchivePlacesModel {
  public private(set) var places: [PlaceSummary]          // 서버 순서 유지 (count desc, name)
  public var mappable: [PlaceSummary] { get }              // lat/lng가 있는 것만
  public private(set) var selectedEntries: [ArchiveItem]
  public private(set) var errorMessage: String?
  public init(api: DiaryAPI)
  public func load() async
  public func select(_ place: PlaceSummary) async          // entriesAtPlace(placeKey)
}
```
- 화면 구성:
  - 위쪽 지도(높이 약 40%): SwiftUI `Map`에 `Annotation`을 둔다. 원 안에 곡 수를 쓰고, 색은 내 `star_color`다. 처음 영역은 `mappable` 전체가 보이게 맞추고, 하나도 없으면 서울 시청 기준 넓은 영역(37.5665, 126.9780, 반경 약 20km)이다.
  - 아래 목록 "자주 들은 곳": 행마다 아트워크, 장소 이름, `"\(n)곡"`. 행을 탭하면 그 장소의 기록 목록으로 가고, 거기서 행을 탭하면 Task 9의 상세로 간다.
  - 장소가 없으면 `"장소와 함께 기록하면 여기에 모여요."`를 보여준다.

- [ ] **Step 1: 실패 테스트**
  - `test_mappableExcludesNameOnly`
  - `test_preservesServerOrder`
  - `test_selectLoadsEntries`: 호출 인자가 해당 `placeKey`
  - `test_loadErrorShowsMessage`
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS, BUILD SUCCEEDED
- [ ] **Step 5: Commit** `feat(ios): archive places with map and list`

---

### Task 11: 앱 껍데기, 테마, 끝에서 끝까지 확인

**Files:**
- Create: `ios/MusicDiary/App/MainTabView.swift`, `ios/MusicDiary/App/Theme.swift`, `ios/README.md`
- Modify: `RootView.swift`(ready → MainTabView), `ComposeView` 성공 콜백 연결

**Interfaces:**
- Produces:
  - `MainTabView(profile: Profile, …)`: 탭 세 개(`피드`, `＋기록`, `아카이브`)이고 SF Symbols는 `music.note.list`, `plus.circle.fill`, `square.grid.2x2`다.
    - 피드 탭: `"친구들의 기록은 곧 여기에 보여요."` 자리 표시
    - 아카이브 탭: 위쪽 세그먼트 `[날짜 | 장소]`, 오른쪽 위 프로필 메뉴(`@handle`, 이름, "로그아웃")
  - 기록 성공 → 아카이브 탭의 날짜 화면으로 전환하고 `refreshAfterChange()`를 부른다.
  - `Theme`:
    - 배경 `#0F0F14`, 카드 `#1E1E28`, 보조 글자 `#9A9AA8`
    - 강조색은 `Color(hex: profile.starColor)`
    - `.preferredColorScheme(.dark)` 고정
  - `ios/README.md`(한국어): 준비물, `Local.xcconfig` 채우는 법, `scripts/ios-check.sh`, 통합 테스트 실행법, 시뮬레이터 실행법, Apple 로그인과 MusicKit을 쓰려면 App ID 설정이 필요하다는 점.

- [ ] **Step 1:** `bash scripts/ios-check.sh`(통합 env 포함) → 모든 단위 테스트, 통합 테스트 PASS, BUILD SUCCEEDED
- [ ] **Step 2: 시뮬레이터 끝에서 끝까지(로컬 Supabase).** 단계마다 스크린샷을 리포트에 남긴다.
  1. 개발용 로그인
  2. 온보딩: `tester`, `테스터`
  3. ＋기록에서 곡 검색 후 선택. App ID의 MusicKit이 아직 꺼져 있어서 검색이 안 되면, 여기서 멈추고 4–7번은 Task 3 통합 테스트 결과로 대신한다. 이 사실을 리포트에 명시한다.
  4. 장소 직접 입력 "집", 코멘트, `나만 보기`로 기록
  5. 아카이브 날짜 칸에 나타남
  6. 장소 탭 목록에 "집 1곡"
  7. 상세에서 코멘트 수정 후 삭제
- [ ] **Step 3: Commit** `feat(ios): app shell, theme, README`
