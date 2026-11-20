# PR Review Assistant for macOS

사람 리뷰어의 GitHub PR 피드백을 감지하고, PR 브랜치를 명시적으로 체크아웃한 상태에서 Cursor Agent로 대응을 분석하는 macOS 앱입니다.

## 제공 기능

- GitHub CLI 인증 상태 확인 및 로컬 GitHub 저장소 등록
- 등록 저장소의 열린 PR·라인 코멘트 폴링과 macOS 알림
- PR의 `head`/`base`/SHA 표시 및 코멘트별 검토, **전체 검토**(검토하지 않은 카드 일괄 실행)
- PR 브랜치 체크아웃, 최신 SHA·브랜치 연결 상태 검증, Cursor 읽기 전용 분석
- 사용자 승인 후 테스트 실행, 커밋·일반 푸시, 재리뷰 요청
- **머지 충돌 감지와 충돌해결하기:** 기준 브랜치를 머지하며 에이전트가 충돌을 해결하고 성공 시 푸시합니다(방향이 다르면 머지를 취소하고 질문).
- **안전 머지:** 승인된 PR을 Create a merge commit 방식으로 머지하며 `--match-head-commit`으로 검토한 SHA와 다르면 머지하지 않습니다.
- **UnitTest 생성:** 브랜치 diff의 비즈니스 로직 또는 **Spec 탭**에서 고른 spec 문서를 기준으로 NUnit 테스트를 생성·검증합니다(`unittest/` 로컬 브랜치에서 작업, 커밋·푸시 없음). 현재 C# 소스가 있는 저장소(`dotnet test`)만 지원하며, C# 소스가 없으면 버튼이 꺼집니다.
- 등록 저장소·처리한 코멘트·분석 결과의 로컬 보관
- macOS 기본 UI와 기본/다크 테마

## 설치

### 1. 사전 조건 설치

- macOS 14 이상
- Git
- GitHub CLI 설치 및 로그인

```zsh
brew install gh
gh auth login
```

- Cursor Agent 로그인(분석·UnitTest 기능)

```zsh
cursor agent login
```

### 2. 앱 설치 (릴리스 다운로드, 권장)

1. [Releases](https://github.com/jenemia/PRReviewAssistant/releases/latest)에서 `PR.Review.Assistant-v<버전>.zip`을 내려받습니다.
2. zip을 풀고 `PR Review Assistant.app`을 `/Applications`로 옮깁니다.
3. 공증되지 않은 빌드라 처음 열 때 "확인되지 않은 개발자" 경고가 나올 수 있습니다. 아래 명령으로 격리 속성을 제거한 뒤 실행하세요(또는 앱을 우클릭 → 열기).

```zsh
xattr -dr com.apple.quarantine "/Applications/PR Review Assistant.app"
open "/Applications/PR Review Assistant.app"
```

### 3. 소스에서 빌드

Xcode 또는 Swift 툴체인이 필요합니다.

```zsh
git clone https://github.com/jenemia/PRReviewAssistant.git
cd PRReviewAssistant
scripts/package-app.sh
open "dist/PR Review Assistant.app"
```

### 4. 첫 실행

1. 앱에서 GitHub 인증 상태를 확인합니다.
2. 저장소 관리에서 PR을 검토할 로컬 GitHub 저장소 폴더를 등록합니다. 등록하면 **프로젝트 규칙** 창이 열립니다(아래 [팀 규칙 설정](#팀-규칙-설정)).
3. 설정에서 사용할 모델을 고릅니다.

앱은 GitHub 토큰을 저장하지 않고 `gh` 인증을 사용합니다. 분석은 기본적으로 읽기 전용이며, 푸시와 재리뷰 요청은 앱에서 각각 승인해야 합니다.

## 계정과 저장소 접근

앱에는 특정 사람의 계정, 토큰, 비밀번호, 개인 경로가 들어 있지 않습니다. 모든 접근은 앱을 실행하는 사용자의 로컬 로그인 상태를 그대로 따릅니다.

| 대상 | 앱이 쓰는 것 | 사용자가 할 일 |
|---|---|---|
| GitHub API (PR·코멘트·머지·리뷰 요청) | `gh` CLI의 로그인 세션. 토큰은 앱에 저장하지 않습니다. | `gh auth login`으로 로그인하고 `gh auth status`로 확인합니다. |
| 저장소 접근 권한 | `gh` 계정의 권한 | 접근 권한이 없는 저장소는 `gh` 오류로 실패합니다. 조직 저장소는 SSO 승인(`gh auth refresh`)이 필요할 수 있습니다. |
| 커밋 작성자 | `git config --global user.name`, `user.email` | 두 값을 설정합니다. 비어 있으면 첫 실행 안내의 Git 계정 확인에서 알려 줍니다. |
| 저장소 목록 | 사용자가 등록한 로컬 폴더. 저장소 이름은 선택한 원격(기본 `origin`)의 URL에서 읽습니다. | 설정 → 저장소에서 GitHub 저장소를 clone한 폴더를 등록합니다. |
| LLM Agent | 선택한 CLI(Cursor, Claude Code, Codex)의 로그인 세션 | 설정 → LLM Agent에서 고른 CLI에 로그인합니다(예: `cursor agent login`). |
| 앱 업데이트 확인 | 공개 저장소 `jenemia/PRReviewAssistant`의 Release | 별도 권한이 필요 없습니다. |

- 앱 상태(등록 저장소, 처리한 코멘트, 분석 결과, 설정)는 `~/Library/Application Support/PRReviewAssistant/state.json`에만 저장됩니다.
- `git`, `gh`, 에이전트 CLI는 `PATH`, `~/.local/bin`, `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin` 순서로 찾습니다. 다른 위치에 설치했다면 이 중 한 곳에 링크를 두세요.
- 저장소마다 사용할 원격을 고를 수 있습니다(프로젝트 규칙 → 원격). 앱은 이 원격에서 PR 브랜치를 가져오고 이 원격으로 푸시합니다. fork의 브랜치로 원본 저장소에 PR을 여는 흐름(원본과 푸시 원격이 다른 경우)은 아직 지원하지 않습니다.
- Terminal에서 여는 로그인 명령(`gh`, Cursor, Claude Code, Codex)은 `~/.local/bin`, `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`을 `PATH` 앞에 붙여 실행합니다.

## 팀 규칙 설정

브랜치 규칙처럼 프로젝트마다 다른 값은 저장소마다 지정합니다. 설정 → 저장소에서 저장소를 등록하면 **프로젝트 규칙** 창이 열리고, 나중에는 저장소 행의 ‘프로젝트 규칙’ 버튼으로 엽니다. 저장을 눌러야 반영됩니다.

- **원격:** PR 브랜치를 가져오고 푸시하는 원격입니다. 감시할 GitHub 저장소도 이 원격의 URL에서 읽습니다.
- **부모 브랜치 규칙:** 브랜치를 어느 브랜치와 비교하고 PR을 어디로 머지해야 하는지 정합니다. 브랜치 리뷰의 비교 기준, PR 머지 대상 확인, UnitTest 작업 브랜치 이름(`sprint/s29/feature/x` → `sprint/s29/unittest/x`)에 쓰입니다.
  - 한 줄에 `head 패턴 -> 부모 브랜치` 하나씩 쓰고, 위에서부터 처음 맞는 줄을 씁니다. `*`는 경로 한 칸, `**`는 남은 경로 전체(맨 끝에만)와 맞고, 부모 브랜치의 `$1`, `$2`는 `*`로 맞은 값입니다. `#`으로 시작하는 줄은 주석입니다.
  - 맞는 줄이 없거나 내용을 비우면 저장소 기본 브랜치를 씁니다. 새로 등록한 저장소는 비어 있고, 이 기능 이전에 등록한 저장소는 `sprint/*/** -> sprint/$1/main`을 유지합니다.
  - **스킬로 규칙 정의:** 팀의 브랜치·PR 규칙이 적힌 Markdown(또는 `SKILL.md`가 있는 폴더)을 고르면, 설정된 LLM Agent가 스킬과 원격 브랜치 이름만 읽고 규칙 초안을 만듭니다. 스킬의 근거 문장과 규칙으로 옮기지 못한 내용(생성 시점·날짜처럼 이름만으로 정할 수 없는 규칙)을 함께 보여 줍니다. 미리보기에서 실제 원격 브랜치의 부모를 확인하고 고친 뒤 저장합니다. 머지 판단은 저장한 규칙으로만 하며, 에이전트가 매번 스킬을 해석하지 않습니다.
  - 저장한 뒤 스킬 파일 내용이 바뀌면 저장소 목록과 규칙 창에 알림이 뜹니다. 규칙은 자동으로 바뀌지 않으니 다시 정의해 확인하세요.
- **spec 폴더:** Spec 탭이 `spec.md`를 찾을 폴더 이름입니다(쉼표로 구분). 기본값은 `specs`, `.specs`입니다.

모든 저장소에 공통인 값은 설정 → **팀 규칙** 탭에서 지정합니다.

- **리뷰 역할 지침 폴더:** 역할별 리뷰가 읽는 `<역할>.md` 파일의 폴더입니다. 기본값은 `~/.cursor/agents`입니다. 파일이 없거나 비어 있는 역할은 앱의 기본 지침으로 리뷰합니다.

## 개발

개발 실행:

```zsh
swift run PRReviewAssistant
```

테스트 실행(실행된 테스트가 0개이면 실패):

```zsh
scripts/test.sh
```

배포본 재생성(`dist/PR Review Assistant.app`과 버전 zip):

```zsh
scripts/package-app.sh
```

`v*` 태그를 푸시하면 GitHub Actions(`release.yml`)가 빌드해 GitHub Release에 zip을 올립니다. 태그는 `Resources/Info.plist`의 버전과 같아야 합니다.

## 역할별 리뷰

앱은 실행할 때 리뷰 역할 지침 폴더(기본 `~/.cursor/agents/`)의 역할 파일을 읽고, 담당별로 독립된 Cursor CLI 세션을 실행합니다. 전역 파일을 수정하면 다음 리뷰부터 적용됩니다. 모든 리뷰 세션은 앱에서 선택한 모델과 읽기 전용 ask 모드를 사용합니다. JSON 완료 응답의 성공 상태와 최종 본문을 검증하며, 계획 생성 도구를 보고서 출력으로 사용하지 않습니다.

- **브랜치 리뷰:** `spec-search-agent`와 `structure-agent`가 병렬 조사한 뒤, `code-reviewer`와 `maintenance-reviewer`가 병렬 검토합니다. 구현 담당은 `scope-guard` 기준도 적용하고, 유지보수 담당은 위험한 변경에 `risk-guard` 기준을 적용합니다. 마지막 통합 세션이 근거를 확인하고 중복·충돌을 정리합니다.
- **리뷰 코멘트 검토:** PR 전체 분석과 코멘트 카드의 첫 분석·재시도에 적용됩니다. `structure-agent`가 관련 기능별 실제 경로와 방어 로직을 조사하고, `code-reviewer`가 코멘트별 지적의 타당성과 제안한 수정의 적절성을 따로 검토합니다. 마지막 통합 세션이 판단과 검증 공백을 정리합니다. 카드의 후속 질문은 기존 단일 세션으로 답변합니다.

필요한 역할의 `.md` 파일이 없거나 비어 있으면 앱의 기본 지침으로 대신합니다. 단계가 실패하거나 빈 응답을 반환하면 후속 단계와 결과 저장을 진행하지 않습니다. 코드는 시작 시 고정한 SHA를 기준으로 조사하며, 완료 시 head 또는 base가 바뀌었으면 재검토가 필요합니다. 테스트·빌드 실행은 리뷰에 포함하지 않고 필요한 검증으로 보고합니다.

Cursor CLI가 종료 코드 0과 함께 표준 오류(stderr)에만 승인·인증 요청을 반환해도 해당 안내를 보존합니다. 코멘트 카드에서는 기존 권한 승인 창으로 연결하며, 오류에는 실패한 담당 단계도 표시합니다.

브랜치 리뷰는 총 5회, 코멘트 검토는 총 3회 모델을 호출하므로 단일 세션보다 사용량이 늘고 시간이 더 걸릴 수 있습니다. 전역 역할은 복사하거나 변경하지 않습니다. 이 흐름은 현재 앱의 Cursor 실행 경로에 적용되며 Codex 역할 파일은 사용하지 않습니다.

# 배포용 DMG 만들기

다른 Mac에서 보안 경고 없이 앱을 열려면, DMG 파일 자체가 아니라 앱을 **Developer ID Application** 인증서로 서명하고 Apple 공증(notarization)을 받아야 합니다. `scripts/package-release-dmg.sh`는 이 과정을 수행합니다.

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='PRReviewAssistantNotary'
scripts/package-release-dmg.sh
```

`NOTARY_PROFILE`은 한 번만 아래 명령으로 로그인 키체인에 만들어 둡니다.

```sh
xcrun notarytool store-credentials 'PRReviewAssistantNotary'
```
