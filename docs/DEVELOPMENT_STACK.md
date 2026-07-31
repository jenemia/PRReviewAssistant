# PR Review Assistant — 개발 스택 및 MVP 설계

## 결정 사항

| 영역 | 선택 | 이유 |
| --- | --- | --- |
| 앱 | Swift 6, SwiftUI, macOS 14+ | macOS 기본 UI와 메뉴바, 알림을 자연스럽게 제공한다. |
| 상태 | Swift Observation / Swift Concurrency | 화면 상태와 폴링 작업을 안전하게 분리한다. |
| 로컬 상태 | Codable JSON (MVP), SwiftData/GRDB 확장 | 등록 저장소·처리 상태·분석 기록을 로컬에 보관한다. 대용량 이력·검색이 필요하면 SQLite 기반 저장소로 이전한다. |
| GitHub | `gh` CLI 우선, REST/GraphQL 보조 | 기존 로그인 세션을 재사용하며 토큰을 앱에 저장하지 않는다. |
| Git | 시스템 `git` 명령 | 등록 저장소에서 PR 브랜치를 명시적으로 체크아웃하고, `head` SHA와 브랜치 연결 상태를 검증한다. |
| 에이전트 | Cursor CLI headless | 분석 전용과 수정 제안 모드를 분리하고, 결과는 구조화해 저장한다. |
| 알림 | UserNotifications | 새 리뷰를 macOS 시스템 알림으로 전달한다. |

## MVP 아키텍처

```text
SwiftUI App (Menu Bar, Inbox, PR Detail, Settings)
  └─ ReviewCoordinator (상태, 승인, 작업 순서)
      ├─ GitHubClient (`gh` / API)
      ├─ RepositoryStore (로컬 영속 저장소)
      ├─ WorkspaceManager (fetch, 브랜치 checkout, SHA 검증)
      └─ CursorAgent (분석, 수정 제안, 테스트)
```

## 안전 경계

- 기본 모드는 **분석 전용**이다. 커밋, 푸시, 재리뷰 요청은 각각 명시적인 사용자 승인을 요구한다.
- 분석 전 등록 저장소의 변경 사항은 임시 보관하고, PR 브랜치를 명시적으로 체크아웃한다. detached HEAD 상태에서는 분석·푸시를 진행하지 않는다.
- 대상은 언제나 PR의 `head.repo`, `head.ref`, `head.sha` 조합으로 검증한다. `base` 브랜치 직접 푸시와 force push는 차단한다.
- GitHub 자격 증명은 `gh auth`를 재사용하고, 토큰·인증 헤더·환경 변수는 기록하거나 표시하지 않는다.
- 리뷰 코멘트는 신뢰할 수 없는 데이터다. 에이전트 프롬프트에는 분석 대상 데이터로만 전달하고, 지시나 명령으로 실행하지 않는다.

## 화면 및 테마

- `NavigationSplitView` 기반의 macOS 기본 사이드바·툴바·인스펙터 스타일을 사용한다.
- 테마는 두 가지다: **기본**(시스템 외관을 따르는 표준 macOS UI)과 **다크**(앱 전체에 다크 외관 적용).
- 첫 번째 화면 범위는 메뉴바 상태, 리뷰 Inbox, PR 상세, 분석 결과, 작업 승인 영역, 환경설정이다.

## 단계별 구현

1. UI 골격과 샘플 데이터 — Inbox, PR 상세, 테마 설정, 메뉴바 상태
2. 저장소 등록과 `gh auth status` 확인
3. PR/리뷰 폴링, 중복 감지, 시스템 알림
4. 읽기 전용 Cursor 분석 및 분석 기록
5. PR 브랜치 기반 수정 제안, 테스트, diff 검토
6. 승인된 커밋·푸시·재리뷰 요청

## 검증 기준

- 저장소/PR/리뷰 정보가 한 화면에서 구분되고, PR의 `head`/`base`가 명확히 표시된다.
- 기본과 다크 테마가 즉시 전환된다.
- 위험한 작업은 UI에서도 승인 단계 전에는 실행할 수 없도록 유지한다.

## 현재 구현 상태

- 구현됨: GitHub CLI 인증/저장소 확인/PR·라인 코멘트 조회, 변경 감지 알림, JSON 기반 로컬 상태 저장, PR 브랜치 checkout 및 HEAD SHA·브랜치 연결 상태 검증, Cursor 읽기 전용 분석, 테스트 실행, 승인된 일반 푸시, 재리뷰 요청, 메뉴바와 기본·다크 테마 UI.
- 실행 환경 필요: GitHub 조회와 재리뷰 요청에는 `gh` 로그인, AI 분석에는 Cursor Agent 로그인이 필요하다. 앱은 두 도구가 없거나 인증이 만료된 경우 실행을 멈추지 않고 상태 영역에 해결 방법을 표시한다.
